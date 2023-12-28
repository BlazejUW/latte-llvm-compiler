{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use lambda-case" #-}

module Latte.Compiler where

import Control.Monad.Except (MonadError (throwError))
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State (StateT, execStateT, get, gets, modify, put)
import Data.Map (Map, adjust, delete, insert)
import qualified Data.Map as Map
import Data.Maybe (isJust)
import Data.List (intercalate)
import qualified Latte.Abs
import Latte.Helpers (Type (Boolean, Integer, String, Void), errLocation, functionName, keywordToType, name, typeToKeyword, typeToLlvmKeyword, convertToLlvmChar)
import Data.Void (Void)
import qualified Distribution.Simple as Latte

data CompilerState = CompilerState
  {
    compilerOutput :: CompilerOutput,
    compilerVariables :: Map String Type,
    indirectVariablesCounter :: Int,
    labelCounter :: Int,
    functionsSignatures :: Map (Latte.Abs.Ident, [Type]) Type,
    exprTypes :: Map Latte.Abs.Expr Type,
    functionToDeclare :: Map (Latte.Abs.Ident, [Type]) Type,
    arguments :: Map String Type,
    stringPool :: Map String Int
  }
  deriving (Eq, Ord, Show)

type LCS a = StateT CompilerState (Either CompilerError) a
type CompilerError = String
type CompilerOutput = [String]

getExpressionType :: Latte.Abs.Expr -> LCS Type
getExpressionType expr = do
  s <- get
  case Map.lookup expr (exprTypes s) of
    Just t -> return t
    Nothing -> throwError $ "Expression type not found: " ++ show expr

class CompileExpr a where
  compilerExpr :: a -> LCS String

instance CompileExpr Latte.Abs.Expr where
  compilerExpr = \case
    Latte.Abs.ELitInt _ val -> return (show val)
    Latte.Abs.ELitTrue _ -> return "1"
    Latte.Abs.ELitFalse _ -> return "0"
    Latte.Abs.EString _ str -> do
      stringId <- findOrDeclareString str
      let strLabel = "@str" ++ show stringId
      let llvmString = convertToLlvmString str
      let stringLength = length str + 1
      nextIndirectVariable <- getNextIndirectVariableAndUpdate
      -- --add srtLabel to variables
      -- let varType = String
      -- modify $ \s -> s { compilerVariables = Map.insert strLabel varType (compilerVariables s)}
      let declaration = strLabel ++ " = private unnamed_addr constant [" ++ show stringLength ++ " x i8] c\"" ++ llvmString ++ "\""
      let call = "%"++ show nextIndirectVariable ++ " = getelementptr inbounds [" ++ show stringLength ++ 
                  " x i8], [" ++ show stringLength ++ " x i8]* " ++ strLabel ++ ", i32 0, i32 0"
      modify $ \s -> s {compilerOutput = declaration : compilerOutput s}
      modify $ \s -> s {compilerOutput = compilerOutput s ++ [call]}
      return $ "%" ++ show nextIndirectVariable
    Latte.Abs.EAdd p l op r -> do
      l' <- compilerExpr l
      r' <- compilerExpr r
      let op' = case op of
            Latte.Abs.Plus _ -> "add"
            Latte.Abs.Minus _ -> "sub"
      counter <- getNextIndirectVariableAndUpdate
      modify $ \s -> s { compilerOutput = compilerOutput s ++ ["%" ++ show counter ++ " = " ++ op' ++ " i32 " ++ l' ++ ", " ++ r']}
      return $ "%" ++ show counter
    Latte.Abs.EMul p l op r -> do
      l' <- compilerExpr l
      r' <- compilerExpr r
      let op' = case op of
            Latte.Abs.Times _ -> "mul"
            Latte.Abs.Div _ -> "sdiv"
            Latte.Abs.Mod _ -> "srem"
      counter <- getNextIndirectVariableAndUpdate
      modify $ \s -> s { compilerOutput = compilerOutput s ++ ["%" ++ show counter ++ " = " ++ op' ++ " i32 " ++ l' ++ ", " ++ r']}
      return $ "%" ++ show counter
    Latte.Abs.Neg p expr -> do
      e <- compilerExpr expr
      counter <- getNextIndirectVariableAndUpdate
      let negInstr = "%" ++ show counter ++ " = sub i32 0, " ++ e
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [negInstr] }
      return $ "%" ++ show counter
    Latte.Abs.EAnd p l r -> do
      lExpr <- compilerExpr l
      rExpr <- compilerExpr r
      counter <- getNextIndirectVariableAndUpdate
      let andInstr = "%" ++ show counter ++ " = and i1 " ++ lExpr ++ ", " ++ rExpr
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [andInstr] }
      return $ "%" ++ show counter
    Latte.Abs.EOr p l r -> do
      lExpr <- compilerExpr l
      rExpr <- compilerExpr r
      counter <- getNextIndirectVariableAndUpdate
      let orInstr = "%" ++ show counter ++ " = or i1 " ++ lExpr ++ ", " ++ rExpr
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [orInstr] }
      return $ "%" ++ show counter
    Latte.Abs.Not p expr -> do
      e <- compilerExpr expr
      counter <- getNextIndirectVariableAndUpdate
      let notInstr = "%" ++ show counter ++ " = xor i1 " ++ e ++ ", 1"
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [notInstr] }
      return $ "%" ++ show counter
    Latte.Abs.ERel p l op r -> do
      lExpr <- compilerExpr l
      rExpr <- compilerExpr r
      counter <- getNextIndirectVariableAndUpdate
      let relOp = case op of
            Latte.Abs.LTH _ -> "slt"
            Latte.Abs.LE _ -> "sle"
            Latte.Abs.GTH _ -> "sgt"
            Latte.Abs.GE _ -> "sge"
            Latte.Abs.EQU _ -> "eq"
            Latte.Abs.NE _ -> "ne"
      let relInstr = "%" ++ show counter ++ " = icmp " ++ relOp ++ " i32 " ++ lExpr ++ ", " ++ rExpr
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [relInstr] }
      return $ "%" ++ show counter 
    Latte.Abs.EVar p ident -> do
      s <- get
      let varName = name ident
      case Map.lookup varName (compilerVariables s) of
        Just varType -> do
          counter <- getNextIndirectVariableAndUpdate
          let loadInstr = if Map.member varName (arguments s)
                          then "%" ++ show counter ++ " = " ++ typeToLlvmKeyword varType ++ " %" ++ varName
                          else "%" ++ show counter ++ " = load " ++ typeToLlvmKeyword varType ++ ", " ++ typeToLlvmKeyword varType ++ "* %" ++ varName
          modify $ \s -> s { compilerOutput = compilerOutput s ++ [loadInstr]}
          return $ "%" ++ show counter
        Nothing -> throwError $ "Variable not defined: " ++ varName

    Latte.Abs.EApp p ident exprs -> do
      argExprs <- mapM compilerExpr exprs
      s <- get
      argTypes <- mapM getExpressionType exprs
      let funType = case Map.lookup (ident, argTypes) (functionsSignatures s) of
            Just t -> t
            _ -> error $ "Function " ++ functionName (ident, argTypes) ++ " not found"
      let argsCall = intercalate ", " (zipWith (\ t e -> t ++ " " ++ e) (map typeToLlvmKeyword argTypes) argExprs)
      let funCall = "call " ++ typeToLlvmKeyword funType ++ " @" ++ name ident ++ "(" ++ argsCall ++ ")" 
      case funType of
        Void -> do
          modify $ \s -> s { compilerOutput = compilerOutput s ++ [funCall] }
          return ""
        _ -> do
          counter <- getNextIndirectVariableAndUpdate
          let callInstr = "%" ++ show counter ++ " = " ++ funCall
          modify $ \s -> s { compilerOutput = compilerOutput s ++ [callInstr]}
          return $ "%" ++ show counter
      -- jeśli return type to void to nie zwracamy nic, w przeciwnym wypadku zwracamy kolejny counter
      

getVariableType :: String -> LCS Type
getVariableType identifier = do
  state <- get
  let variables = compilerVariables state
  let variableType = case Map.lookup identifier variables of
                  Just t -> t
                  _ -> error $ "Variable " ++ identifier ++ " not found"
  return variableType

getNextIndirectVariableAndUpdate :: LCS Int
getNextIndirectVariableAndUpdate = do
  s <- get
  let counter = indirectVariablesCounter s + 1
  modify $ \s -> s { indirectVariablesCounter = counter }
  return counter

getNextLabelCounterAndUpdate :: LCS Int
getNextLabelCounterAndUpdate = do
  s <- get
  let counter =  labelCounter s + 1
  modify $ \s -> s { labelCounter = counter }
  return counter

findOrDeclareString :: String -> LCS Int
findOrDeclareString str = do
  s <- get
  let stringPool = Latte.Compiler.stringPool s
  case Map.lookup str stringPool of
    Just index -> return index
    Nothing -> do
      let index = Map.size stringPool
      modify $ \s -> s { stringPool = Map.insert str index stringPool }
      return index

convertToLlvmString :: String -> String
convertToLlvmString s = concatMap convertToLlvmChar s ++ "\\00"


combineTypeAndIndentOfExpr :: Latte.Abs.Expr -> String -> LCS String
combineTypeAndIndentOfExpr expr exprStr = do
  exprType <- getExpressionType expr
  return $ typeToLlvmKeyword exprType ++ " " ++ exprStr

class Compile a where
  compile :: a -> LCS ()


instance Compile Latte.Abs.Program where
    compile (Latte.Abs.Program _ topdefs) = do
        forM_ topdefs compile


printArg :: Latte.Abs.Arg -> String
printArg (Latte.Abs.Arg _ argType ident) =
    typeToLlvmKeyword (keywordToType argType) ++ " %" ++ name ident


instance Compile Latte.Abs.TopDef where
  compile fndef@(Latte.Abs.FnDef p t ident args block) = do
    let retType = keywordToType t
    let argsStr = intercalate ", " (map printArg args)
    forM_ args $ \(Latte.Abs.Arg _ argType ident) -> do
      let varName = name ident
      let varType = keywordToType argType
      modify $ \s -> s { compilerVariables = Map.insert varName varType (compilerVariables s),
                         arguments = Map.insert varName varType (arguments s)}
    let funName = name ident
    let funSignature =  typeToLlvmKeyword retType ++ " @" ++ funName ++ "(" ++ argsStr ++ ")"
    let funHeader = "define " ++ funSignature
    modify $ \s -> s { compilerOutput = compilerOutput s ++ [funHeader] }
    modify $ \s -> s { compilerOutput = compilerOutput s ++ ["{"] }
    indirectVariablesCounter <- gets indirectVariablesCounter
    modify $ \s -> s { indirectVariablesCounter = 0 }
    compile block
    modify $ \s -> s { indirectVariablesCounter = indirectVariablesCounter }
    modify $ \s -> s { compilerOutput = compilerOutput s ++ ["}"] }
    forM_ args $ \(Latte.Abs.Arg _ _ ident) -> do
      let varName = name ident
      modify $ \s -> s { compilerVariables = Map.delete varName (compilerVariables s),
                         arguments = Map.delete varName (arguments s)}



instance Compile Latte.Abs.Block where
    compile (Latte.Abs.Block _ stmts) = do
        forM_ stmts compile


instance Compile Latte.Abs.Stmt where
  compile = \case
    Latte.Abs.Empty _ -> return ()
    Latte.Abs.BStmt _ block -> compile block
    Latte.Abs.Decl p type_ items -> forM_ items $ \item -> case item of
      Latte.Abs.NoInit _ ident -> do
        let varName = name ident
        let varType = keywordToType type_
        modify $ \s -> s { compilerVariables = Map.insert varName varType (compilerVariables s)}
        let varDeclaration = "%" ++ varName ++ " = alloca " ++ typeToLlvmKeyword varType
        modify $ \s -> s { compilerOutput = compilerOutput s ++ [varDeclaration] }
      Latte.Abs.Init _ ident expr -> do
        let varName = name ident
        let varType = keywordToType type_
        modify $ \s -> s { compilerVariables = Map.insert varName varType (compilerVariables s)}
        let varDeclaration = "%" ++ varName ++ " = alloca " ++ typeToLlvmKeyword varType
        modify $ \s -> s { compilerOutput = compilerOutput s ++ [varDeclaration] }
        e <- compilerExpr expr
        exprWithType <- combineTypeAndIndentOfExpr expr e
        let varAssignment = "store " ++ exprWithType ++ ", " ++ typeToLlvmKeyword varType ++ "* %" ++ varName
        modify $ \s -> s { compilerOutput = compilerOutput s ++ [varAssignment]}
    Latte.Abs.Ass p ident expr -> do
      s <- get
      let varName = name ident
      case Map.lookup varName (compilerVariables s) of
        Just varType -> do
          e <- compilerExpr expr
          exprWithType <- combineTypeAndIndentOfExpr expr e
          if Map.member varName (arguments s) then do
            counter <- getNextIndirectVariableAndUpdate
            let allocaInstr = "%" ++ show counter ++ " = alloca " ++ typeToLlvmKeyword varType
            let storeInstr = "store " ++ exprWithType ++ ", " ++ typeToLlvmKeyword varType ++ "* %" ++ show counter
            modify $ \s -> s {
              compilerOutput = compilerOutput s ++ [allocaInstr, storeInstr]
            }
          else do
            let storeInstr = "store " ++ exprWithType ++ ", " ++ typeToLlvmKeyword varType ++ "* %" ++ varName
            modify $ \s -> s {
              compilerOutput = compilerOutput s ++ [storeInstr]
            }
        Nothing -> throwError $ "Variable not defined: " ++ varName
    Latte.Abs.Cond p expr stmt -> do
      e <- compilerExpr expr
      counter <- getNextLabelCounterAndUpdate
      let trueLabel = "if_true_" ++ show counter
      let endLabel = "if_end_" ++ show counter
      modify $ \s -> s { compilerOutput = compilerOutput s ++ ["br i1 " ++ e ++ ", label %" ++ trueLabel ++ ", label %" ++ endLabel] }
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [trueLabel ++ ":"] }
      compile stmt
      let br_instruction = "br label %" ++ endLabel
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [br_instruction, endLabel ++ ":"] } --TODO sprawdzić na students czy też potrzeba br
    Latte.Abs.CondElse p expr stmt1 stmt2 -> do
      e <- compilerExpr expr
      counter <- getNextLabelCounterAndUpdate
      let trueLabel = "if_true_" ++ show counter
      let falseLabel = "if_false_" ++ show counter
      let endLabel = "if_end_" ++ show counter
      modify $ \s -> s { compilerOutput = compilerOutput s ++ ["br i1 " ++ e ++ ", label %" ++ trueLabel ++ ", label %" ++ falseLabel] }
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [trueLabel ++ ":"] }
      compile stmt1
      modify $ \s -> s { compilerOutput = compilerOutput s ++ ["br label %" ++ endLabel] }
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [falseLabel ++ ":"] }
      compile stmt2
      modify $ \s -> s { compilerOutput = compilerOutput s ++ ["br label %" ++ endLabel] }
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [endLabel ++ ":"] }
    -- Latte.Abs.While p expr stmt ->     ""
    Latte.Abs.Incr p ident -> do
      commonDecrIncrOperation ident "add"
    Latte.Abs.Decr p ident -> do
      commonDecrIncrOperation ident "sub"
    Latte.Abs.Ret p expr -> do
      e <- compilerExpr expr
      exprWithType <- combineTypeAndIndentOfExpr expr e
      let returnText = "ret" ++ " " ++ exprWithType
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [returnText] }
    Latte.Abs.VRet p -> 
      modify $ \s -> s { compilerOutput = compilerOutput s ++ ["ret void"] }
    Latte.Abs.SExp _ expr -> do --TODO
      e  <- compilerExpr expr
      modify $ \s -> s { compilerOutput = compilerOutput s ++ [e] }
    other -> throwError $ "Not implemented: " ++ show other

commonDecrIncrOperation ident op = do
  s <- get
  let varName = name ident
  case Map.lookup varName (compilerVariables s) of
    Just varType -> do
      if Map.member varName (arguments s) then do
        counter <- getNextIndirectVariableAndUpdate
        let argOperation = "%" ++ show counter ++ " = " ++ op ++ " " ++ typeToLlvmKeyword varType ++ " %" ++ varName ++ ", 1"
        modify $ \s -> s { compilerOutput = compilerOutput s ++ [argOperation] }
      else do
        -- Obsługa zmiennej lokalnej
        counter <- getNextIndirectVariableAndUpdate
        let loadInstr = "%" ++ show counter ++ " = load " ++ typeToLlvmKeyword varType ++ ", " ++ typeToLlvmKeyword varType ++ "* %" ++ varName
        nextCounter <- getNextIndirectVariableAndUpdate
        let opInstr = "%" ++ show nextCounter ++ " = " ++ op ++ " " ++ typeToLlvmKeyword varType ++ " %" ++ show counter ++ ", 1"
        let storeInstr = "store " ++ typeToLlvmKeyword varType ++ " %" ++ show nextCounter ++ ", " ++ typeToLlvmKeyword varType ++ "* %" ++ varName
        modify $ \s -> s { compilerOutput = compilerOutput s ++ [loadInstr, opInstr, storeInstr] }
    Nothing -> throwError $ "Variable not defined: " ++ varName



runCompiler :: (Compile a) => a -> Map (Latte.Abs.Ident, [Type]) Type -> Map Latte.Abs.Expr Type -> Either String CompilerState
runCompiler program functionsSignatures exprTypes = execStateT (compile program) $ CompilerState ["declare i32 @printString(i8* %str)", "declare i32 @printInt(i32 %i)"] 
    Map.empty 0 0 functionsSignatures exprTypes Map.empty Map.empty Map.empty