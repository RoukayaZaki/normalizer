{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant fmap" #-}

module Language.EO.Phi.Dataize where

import Control.Arrow (ArrowChoice (left))
import Data.List (singleton)
import Data.Maybe (listToMaybe)
import Data.String.Interpolate (i)
import Language.EO.Phi (Binding (DeltaEmptyBinding, EmptyBinding))
import Language.EO.Phi.Rules.Common
import Language.EO.Phi.Syntax.Abs (
  AlphaIndex (AlphaIndex),
  Attribute (Alpha, Phi, Rho),
  Binding (AlphaBinding, DeltaBinding, LambdaBinding),
  Bytes (Bytes),
  Function (Function),
  Object (Application, Formation, ObjectDispatch, Termination),
 )

-- | Perform one step of dataization to the object (if possible).
dataizeStep :: Context -> Object -> (Context, Either Object Bytes)
dataizeStep ctx obj = snd $ head $ runChain (dataizeStepChain obj) ctx -- FIXME: head is bad

dataizeStep' :: Context -> Object -> Either Object Bytes
dataizeStep' ctx obj = snd (dataizeStep ctx obj)

-- | State of evaluation is not needed yet, but it might be in the future
type EvaluationState = ()

-- | Recursively perform normalization and dataization until we get bytes in the end.
dataizeRecursively :: Context -> Object -> Either Object Bytes
dataizeRecursively ctx obj = snd $ dataizeRecursivelyChain' ctx obj

dataizeStepChain' :: Context -> Object -> ([(String, Either Object Bytes)], Either Object Bytes)
dataizeStepChain' ctx obj = snd <$> head (runChain (dataizeStepChain obj) ctx) -- FIXME: head is bad

-- | Perform one step of dataization to the object (if possible), reporting back individiual steps.
dataizeStepChain :: Object -> DataizeChain (Context, Either Object Bytes)
dataizeStepChain obj@(Formation bs)
  | Just (DeltaBinding bytes) <- listToMaybe [b | b@(DeltaBinding _) <- bs]
  , not hasEmpty = do
      logStep "Found bytes" (Right bytes)
      ctx <- getContext
      return (ctx, Right bytes)
  | Just (LambdaBinding (Function funcName)) <- listToMaybe [b | b@(LambdaBinding _) <- bs]
  , not hasEmpty = do
      logStep ("Evaluating lambda '" <> funcName <> "'") (Left obj)
      (obj', _state) <- evaluateBuiltinFunChain funcName obj ()
      ctx <- getContext
      return (ctx, Left obj')
  | Just (AlphaBinding Phi decoratee) <- listToMaybe [b | b@(AlphaBinding Phi _) <- bs]
  , not hasEmpty = do
      logStep "Dataizing inside phi" (Left decoratee)
      ctx <- getContext
      let extendedContext = (extendContextWith obj ctx){currentAttr = Phi}
      logStep "Dataizing inside phi" (Left decoratee)
      withContext extendedContext $ dataizeStepChain decoratee
  | otherwise = do
      logStep "No change to formation" (Left obj)
      ctx <- getContext
      return (ctx, Left obj)
 where
  isEmpty (EmptyBinding _) = True
  isEmpty DeltaEmptyBinding = True
  isEmpty _ = False
  hasEmpty = any isEmpty bs
dataizeStepChain (Application obj bindings) = do
  logStep "Dataizing inside application" (Left obj)
  modifyContext (\c -> c{dataizePackage = False}) $ do
    (ctx, obj') <- dataizeStepChain obj
    return (ctx, left (`Application` bindings) obj')
dataizeStepChain (ObjectDispatch obj attr) = do
  logStep "Dataizing inside dispatch" (Left obj)
  modifyContext (\c -> c{dataizePackage = False}) $ do
    (ctx, obj') <- dataizeStepChain obj
    return (ctx, left (`ObjectDispatch` attr) obj')
dataizeStepChain obj = do
  logStep "Nothing to dataize" (Left obj)
  ctx <- getContext
  return (ctx, Left obj)

dataizeRecursivelyChain' :: Context -> Object -> ([(String, Either Object Bytes)], Either Object Bytes)
dataizeRecursivelyChain' ctx obj = head (runChain (dataizeRecursivelyChain obj) ctx)

-- | Recursively perform normalization and dataization until we get bytes in the end,
-- reporting intermediate steps
dataizeRecursivelyChain :: Object -> DataizeChain (Either Object Bytes)
dataizeRecursivelyChain obj = do
  ctx <- getContext
  msplit (transformNormLogs (applyRulesChain obj)) >>= \case
    Nothing -> do
      logStep "No rules applied" (Left obj)
      return (Left obj)
    -- We trust that all chains lead to the same result due to confluence
    Just (normObj, _alternatives) -> do
      (ctx', step) <- dataizeStepChain normObj
      case step of
        (Left stillObj)
          | stillObj == normObj && ctx `sameContext` ctx' -> return step -- dataization changed nothing
          | otherwise -> withContext ctx' $ dataizeRecursivelyChain stillObj -- partially dataized
        bytes -> return bytes

-- | Given converters between Bytes and some data type, a binary function on this data type, an object,
-- and the current state of evaluation, returns the new object and a possibly modified state along with intermediate steps.
evaluateDataizationFunChain
  :: (res -> Bytes) -- ^ How to convert the result back to bytes
  -> (Bytes -> a) -- ^ How to interpret the bytes in terms of the given data type
  -> (Bytes -> Object) -- ^ How to wrap the bytes in an object
  -> (a -> a -> res) -- ^ A binary function on the data
  -> Object
  -> EvaluationState
  -> DataizeChain (Object, EvaluationState)
evaluateDataizationFunChain resultToBytes bytesToParam wrapBytes func obj _state = do
  let o_rho = ObjectDispatch obj Rho
  let o_a0 = ObjectDispatch obj (Alpha (AlphaIndex "α0"))
  logStep "Evaluating LHS" (Left o_rho)
  lhs <- dataizeRecursivelyChain o_rho
  logStep "Evaluating RHS" (Left o_a0)
  rhs <- dataizeRecursivelyChain o_a0
  result <- case (lhs, rhs) of
    (Right l, Right r) -> do
      let bytes = resultToBytes (bytesToParam r `func` bytesToParam l)
          resultObj = wrapBytes bytes
      logStep "Evaluated function" (Left resultObj)
      return resultObj
    _ -> do
      logStep "Couldn't find bytes in one or both of LHS and RHS" (Left Termination)
      return Termination
  return (result, ())

evaluateBinaryDataizationFunChain
  :: (res -> Bytes) -- ^ How to convert the result back to bytes
  -> (Bytes -> a) -- ^ How to interpret the bytes in terms of the given data type
  -> (Bytes -> Object) -- ^ How to wrap the bytes in an object
  -> (Object -> Object) -- ^ Extract the 1st argument to be dataized
  -> (Object -> Object) -- ^ Extract the 2nd argument to be dataized
  -> (a -> a -> res) -- ^ A binary function on the argument
  -> Object
  -> EvaluationState
  -> DataizeChain (Object, EvaluationState)
evaluateBinaryDataizationFunChain resultToBytes bytesToParam wrapBytes arg1 arg2 func obj _state = do
  let lhsArg = arg1 obj
  let rhsArg = arg2 obj
  logStep "Evaluating LHS" (Left lhsArg)
  lhs <- dataizeRecursivelyChain lhsArg
  logStep "Evaluating RHS" (Left rhsArg)
  rhs <- dataizeRecursivelyChain rhsArg
  result <- case (lhs, rhs) of
    (Right l, Right r) -> do
      let bytes = resultToBytes (bytesToParam r `func` bytesToParam l)
          resultObj = wrapBytes bytes
      logStep "Evaluated function" (Left resultObj)
      return resultObj
    _ -> do
      logStep "Couldn't find bytes in one or both of LHS and RHS" (Left Termination)
      return Termination
  return (result, ())

-- This should maybe get converted to a type class and some instances?
evaluateIntIntFunChain :: (Int -> Int -> Int) -> Object -> EvaluationState -> DataizeChain (Object, EvaluationState)
evaluateIntIntFunChain = evaluateBinaryDataizationFunChain
  intToBytes
  bytesToInt
  (\(Bytes bytes) -> [i|Φ.org.eolang.int(Δ ⤍ #{bytes})|])
  (`ObjectDispatch` Rho)
  (`ObjectDispatch` (Alpha (AlphaIndex "α0")))
evaluateIntBoolFunChain :: (Int -> Int -> Bool) -> Object -> EvaluationState -> DataizeChain (Object, EvaluationState)
evaluateIntBoolFunChain = evaluateBinaryDataizationFunChain
  boolToBytes
  bytesToInt
  (\(Bytes bytes) -> [i|Φ.org.eolang.bytes(Δ ⤍ #{bytes})|])
  (`ObjectDispatch` Rho)
  (`ObjectDispatch` (Alpha (AlphaIndex "α0")))

-- | Like `evaluateDataizationFunChain` but specifically for the built-in functions.
-- This function is not safe. It returns undefined for unknown functions
evaluateBuiltinFunChain :: String -> Object -> EvaluationState -> DataizeChain (Object, EvaluationState)
evaluateBuiltinFunChain "Plus" obj = evaluateIntIntFunChain (+) obj -- FIXME: change to float variant
evaluateBuiltinFunChain "Times" obj = evaluateIntIntFunChain (*) obj -- FIXME: change to float variant
evaluateBuiltinFunChain "Lorg_eolang_int_gt" obj = evaluateIntBoolFunChain (>) obj
evaluateBuiltinFunChain "Lorg_eolang_int_plus" obj = evaluateIntIntFunChain (+) obj
evaluateBuiltinFunChain "Lorg_eolang_int_times" obj = evaluateIntIntFunChain (*) obj
evaluateBuiltinFunChain "Lorg_eolang_int_div" obj = evaluateIntIntFunChain div obj
evaluateBuiltinFunChain "Package" (Formation bindings) = do
  \state -> do
    fmap dataizePackage getContext >>= \case
      True -> do
        let (packageBindings, restBindings) = span isPackage bindings
        bs <- mapM dataizeBindingChain restBindings
        logStep "Dataized 'Package' siblings" (Left $ Formation (bs ++ packageBindings))
        return (Formation (bs ++ packageBindings), state)
      False ->
        return (Formation bindings, state)
 where
  isPackage (LambdaBinding (Function "Package")) = True
  isPackage _ = False
  dataizeBindingChain (AlphaBinding attr o) = do
    dataizationResult <- dataizeRecursivelyChain o
    return (AlphaBinding attr (either id (Formation . singleton . DeltaBinding) dataizationResult))
  dataizeBindingChain b = return b
evaluateBuiltinFunChain _ obj = \state -> return (obj, state)

-- | Like `evaluateDataizationFun` but specifically for the built-in functions.
-- This function is not safe. It returns undefined for unknown functions
evaluateBuiltinFun :: Context -> String -> Object -> EvaluationState -> (Object, EvaluationState)
evaluateBuiltinFun ctx name obj state = snd $ head $ runChain (evaluateBuiltinFunChain name obj state) ctx -- FIXME: head is bad
