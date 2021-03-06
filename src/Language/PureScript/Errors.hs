-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.Error
-- Copyright   :  (c) 2013-15 Phil Freeman, (c) 2014-15 Gary Burgess
-- License     :  MIT (http://opensource.org/licenses/MIT)
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE CPP #-}

module Language.PureScript.Errors where

import Data.Either (lefts, rights)
import Data.List (intercalate, transpose, nub, nubBy, partition)
import Data.Function (on)
#if __GLASGOW_HASKELL__ < 710
import Data.Foldable (fold, foldMap)
import Data.Traversable (traverse)
#else
import Data.Foldable (fold)
#endif

import qualified Data.Map as M

import Control.Monad
import Control.Monad.Unify
import Control.Monad.Writer
import Control.Monad.Error.Class (MonadError(..))
#if __GLASGOW_HASKELL__ < 710
import Control.Applicative ((<$>), (<*>), Applicative, pure)
#endif
import Control.Monad.Trans.State.Lazy
import Control.Arrow(first)

import Language.PureScript.AST
import Language.PureScript.Environment (isObject, isFunction)
import Language.PureScript.Pretty
import Language.PureScript.Types
import Language.PureScript.Names
import Language.PureScript.Kinds

import qualified Text.PrettyPrint.Boxes as Box

import qualified Text.Parsec as P
import qualified Text.Parsec.Error as PE
import Text.Parsec.Error (Message(..))

-- | A type of error messages
data SimpleErrorMessage
  = ErrorParsingExterns P.ParseError
  | ErrorParsingFFIModule FilePath
  | ErrorParsingModule P.ParseError
  | MissingFFIModule ModuleName
  | MultipleFFIModules ModuleName [FilePath]
  | UnnecessaryFFIModule ModuleName FilePath
  | InvalidExternsFile FilePath
  | CannotGetFileInfo FilePath
  | CannotReadFile FilePath
  | CannotWriteFile FilePath
  | InfiniteType Type
  | InfiniteKind Kind
  | CannotReorderOperators
  | MultipleFixities Ident
  | OrphanTypeDeclaration Ident
  | OrphanFixityDeclaration String
  | RedefinedModule ModuleName [SourceSpan]
  | RedefinedIdent Ident
  | OverlappingNamesInLet
  | UnknownModule ModuleName
  | UnknownType (Qualified ProperName)
  | UnknownTypeClass (Qualified ProperName)
  | UnknownValue (Qualified Ident)
  | UnknownDataConstructor (Qualified ProperName) (Maybe (Qualified ProperName))
  | UnknownTypeConstructor (Qualified ProperName)
  | UnknownImportType ModuleName ProperName
  | UnknownExportType ProperName
  | UnknownImportTypeClass ModuleName ProperName
  | UnknownExportTypeClass ProperName
  | UnknownImportValue ModuleName Ident
  | UnknownExportValue Ident
  | UnknownExportModule ModuleName
  | UnknownImportDataConstructor ModuleName ProperName ProperName
  | UnknownExportDataConstructor ProperName ProperName
  | ConflictingImport String ModuleName
  | ConflictingImports String ModuleName ModuleName
  | ConflictingTypeDecls ProperName
  | ConflictingCtorDecls ProperName
  | TypeConflictsWithClass ProperName
  | CtorConflictsWithClass ProperName
  | ClassConflictsWithType ProperName
  | ClassConflictsWithCtor ProperName
  | DuplicateModuleName ModuleName
  | DuplicateClassExport ProperName
  | DuplicateValueExport Ident
  | DuplicateTypeArgument String
  | InvalidDoBind
  | InvalidDoLet
  | CycleInDeclaration Ident
  | CycleInTypeSynonym (Maybe ProperName)
  | CycleInModules [ModuleName]
  | NameIsUndefined Ident
  | NameNotInScope Ident
  | UndefinedTypeVariable ProperName
  | PartiallyAppliedSynonym (Qualified ProperName)
  | EscapedSkolem (Maybe Expr)
  | UnspecifiedSkolemScope
  | TypesDoNotUnify Type Type
  | KindsDoNotUnify Kind Kind
  | ConstrainedTypeUnified Type Type
  | OverlappingInstances (Qualified ProperName) [Type] [Qualified Ident]
  | NoInstanceFound (Qualified ProperName) [Type]
  | PossiblyInfiniteInstance (Qualified ProperName) [Type]
  | CannotDerive (Qualified ProperName) [Type]
  | CannotFindDerivingType ProperName
  | DuplicateLabel String (Maybe Expr)
  | DuplicateValueDeclaration Ident
  | ArgListLengthsDiffer Ident
  | OverlappingArgNames (Maybe Ident)
  | MissingClassMember Ident
  | ExtraneousClassMember Ident
  | ExpectedType Type Kind
  | IncorrectConstructorArity (Qualified ProperName)
  | SubsumptionCheckFailed
  | ExprDoesNotHaveType Expr Type
  | PropertyIsMissing String Type
  | CannotApplyFunction Type Expr
  | TypeSynonymInstance
  | OrphanInstance Ident (Qualified ProperName) [Type]
  | InvalidNewtype
  | InvalidInstanceHead Type
  | TransitiveExportError DeclarationRef [DeclarationRef]
  | ShadowedName Ident
  | ShadowedTypeVar String
  | UnusedTypeVar String
  | WildcardInferredType Type
  | MissingTypeDeclaration Ident
  | NotExhaustivePattern [[Binder]] Bool
  | OverlappingPattern [[Binder]] Bool
  | IncompleteExhaustivityCheck
  | ClassOperator ProperName Ident
  | MisleadingEmptyTypeImport ModuleName ProperName
  | ImportHidingModule ModuleName
  deriving Show

-- | Error message hints, providing more detailed information about failure.
data ErrorMessageHint
  = NotYetDefined [Ident]
  | ErrorUnifyingTypes Type Type
  | ErrorInExpression Expr
  | ErrorInModule ModuleName
  | ErrorInInstance (Qualified ProperName) [Type]
  | ErrorInSubsumption Type Type
  | ErrorCheckingType Expr Type
  | ErrorCheckingKind Type
  | ErrorInferringType Expr
  | ErrorInApplication Expr Type Expr
  | ErrorInDataConstructor ProperName
  | ErrorInTypeConstructor ProperName
  | ErrorInBindingGroup [Ident]
  | ErrorInDataBindingGroup
  | ErrorInTypeSynonym ProperName
  | ErrorInValueDeclaration Ident
  | ErrorInTypeDeclaration Ident
  | ErrorInForeignImport Ident
  | PositionedError SourceSpan
  deriving Show

-- | Categories of hints
data HintCategory
  = ExprHint
  | KindHint
  | CheckHint
  | PositionHint
  | OtherHint
  deriving (Show, Eq)

data ErrorMessage = ErrorMessage [ErrorMessageHint] SimpleErrorMessage deriving (Show)

instance UnificationError Type ErrorMessage where
  occursCheckFailed t = ErrorMessage [] $ InfiniteType t

instance UnificationError Kind ErrorMessage where
  occursCheckFailed k = ErrorMessage [] $ InfiniteKind k

-- |
-- Get the error code for a particular error type
--
errorCode :: ErrorMessage -> String
errorCode em = case unwrapErrorMessage em of
  ErrorParsingExterns{} -> "ErrorParsingExterns"
  ErrorParsingFFIModule{} -> "ErrorParsingFFIModule"
  ErrorParsingModule{} -> "ErrorParsingModule"
  MissingFFIModule{} -> "MissingFFIModule"
  MultipleFFIModules{} -> "MultipleFFIModules"
  UnnecessaryFFIModule{} -> "UnnecessaryFFIModule"
  InvalidExternsFile{} -> "InvalidExternsFile"
  CannotGetFileInfo{} -> "CannotGetFileInfo"
  CannotReadFile{} -> "CannotReadFile"
  CannotWriteFile{} -> "CannotWriteFile"
  InfiniteType{} -> "InfiniteType"
  InfiniteKind{} -> "InfiniteKind"
  CannotReorderOperators -> "CannotReorderOperators"
  MultipleFixities{} -> "MultipleFixities"
  OrphanTypeDeclaration{} -> "OrphanTypeDeclaration"
  OrphanFixityDeclaration{} -> "OrphanFixityDeclaration"
  RedefinedModule{} -> "RedefinedModule"
  RedefinedIdent{} -> "RedefinedIdent"
  OverlappingNamesInLet -> "OverlappingNamesInLet"
  UnknownModule{} -> "UnknownModule"
  UnknownType{} -> "UnknownType"
  UnknownTypeClass{} -> "UnknownTypeClass"
  UnknownValue{} -> "UnknownValue"
  UnknownDataConstructor{} -> "UnknownDataConstructor"
  UnknownTypeConstructor{} -> "UnknownTypeConstructor"
  UnknownImportType{} -> "UnknownImportType"
  UnknownExportType{} -> "UnknownExportType"
  UnknownImportTypeClass{} -> "UnknownImportTypeClass"
  UnknownExportTypeClass{} -> "UnknownExportTypeClass"
  UnknownImportValue{} -> "UnknownImportValue"
  UnknownExportValue{} -> "UnknownExportValue"
  UnknownExportModule{} -> "UnknownExportModule"
  UnknownImportDataConstructor{} -> "UnknownImportDataConstructor"
  UnknownExportDataConstructor{} -> "UnknownExportDataConstructor"
  ConflictingImport{} -> "ConflictingImport"
  ConflictingImports{} -> "ConflictingImports"
  ConflictingTypeDecls{} -> "ConflictingTypeDecls"
  ConflictingCtorDecls{} -> "ConflictingCtorDecls"
  TypeConflictsWithClass{} -> "TypeConflictsWithClass"
  CtorConflictsWithClass{} -> "CtorConflictsWithClass"
  ClassConflictsWithType{} -> "ClassConflictsWithType"
  ClassConflictsWithCtor{} -> "ClassConflictsWithCtor"
  DuplicateModuleName{} -> "DuplicateModuleName"
  DuplicateClassExport{} -> "DuplicateClassExport"
  DuplicateValueExport{} -> "DuplicateValueExport"
  DuplicateTypeArgument{} -> "DuplicateTypeArgument"
  InvalidDoBind -> "InvalidDoBind"
  InvalidDoLet -> "InvalidDoLet"
  CycleInDeclaration{} -> "CycleInDeclaration"
  CycleInTypeSynonym{} -> "CycleInTypeSynonym"
  CycleInModules{} -> "CycleInModules"
  NameIsUndefined{} -> "NameIsUndefined"
  NameNotInScope{} -> "NameNotInScope"
  UndefinedTypeVariable{} -> "UndefinedTypeVariable"
  PartiallyAppliedSynonym{} -> "PartiallyAppliedSynonym"
  EscapedSkolem{} -> "EscapedSkolem"
  UnspecifiedSkolemScope -> "UnspecifiedSkolemScope"
  TypesDoNotUnify{} -> "TypesDoNotUnify"
  KindsDoNotUnify{} -> "KindsDoNotUnify"
  ConstrainedTypeUnified{} -> "ConstrainedTypeUnified"
  OverlappingInstances{} -> "OverlappingInstances"
  NoInstanceFound{} -> "NoInstanceFound"
  PossiblyInfiniteInstance{} -> "PossiblyInfiniteInstance"
  CannotDerive{} -> "CannotDerive"
  CannotFindDerivingType{} -> "CannotFindDerivingType"
  DuplicateLabel{} -> "DuplicateLabel"
  DuplicateValueDeclaration{} -> "DuplicateValueDeclaration"
  ArgListLengthsDiffer{} -> "ArgListLengthsDiffer"
  OverlappingArgNames{} -> "OverlappingArgNames"
  MissingClassMember{} -> "MissingClassMember"
  ExtraneousClassMember{} -> "ExtraneousClassMember"
  ExpectedType{} -> "ExpectedType"
  IncorrectConstructorArity{} -> "IncorrectConstructorArity"
  SubsumptionCheckFailed -> "SubsumptionCheckFailed"
  ExprDoesNotHaveType{} -> "ExprDoesNotHaveType"
  PropertyIsMissing{} -> "PropertyIsMissing"
  CannotApplyFunction{} -> "CannotApplyFunction"
  TypeSynonymInstance -> "TypeSynonymInstance"
  OrphanInstance{} -> "OrphanInstance"
  InvalidNewtype -> "InvalidNewtype"
  InvalidInstanceHead{} -> "InvalidInstanceHead"
  TransitiveExportError{} -> "TransitiveExportError"
  ShadowedName{} -> "ShadowedName"
  ShadowedTypeVar{} -> "ShadowedTypeVar"
  UnusedTypeVar{} -> "UnusedTypeVar"
  WildcardInferredType{} -> "WildcardInferredType"
  MissingTypeDeclaration{} -> "MissingTypeDeclaration"
  NotExhaustivePattern{} -> "NotExhaustivePattern"
  OverlappingPattern{} -> "OverlappingPattern"
  IncompleteExhaustivityCheck{} -> "IncompleteExhaustivityCheck"
  ClassOperator{} -> "ClassOperator"
  MisleadingEmptyTypeImport{} -> "MisleadingEmptyTypeImport"
  ImportHidingModule{} -> "ImportHidingModule"

-- |
-- A stack trace for an error
--
newtype MultipleErrors = MultipleErrors
  { runMultipleErrors :: [ErrorMessage] } deriving (Show, Monoid)

instance UnificationError Type MultipleErrors where
  occursCheckFailed t = MultipleErrors [occursCheckFailed t]

instance UnificationError Kind MultipleErrors where
  occursCheckFailed k = MultipleErrors [occursCheckFailed k]

-- | Check whether a collection of errors is empty or not.
nonEmpty :: MultipleErrors -> Bool
nonEmpty = not . null . runMultipleErrors

-- |
-- Create an error set from a single simple error message
--
errorMessage :: SimpleErrorMessage -> MultipleErrors
errorMessage err = MultipleErrors [ErrorMessage [] err]


-- |
-- Create an error set from a single error message
--
singleError :: ErrorMessage -> MultipleErrors
singleError = MultipleErrors . pure

-- | Lift a function on ErrorMessage to a function on MultipleErrors
onErrorMessages :: (ErrorMessage -> ErrorMessage) -> MultipleErrors -> MultipleErrors
onErrorMessages f = MultipleErrors . map f . runMultipleErrors

-- | Add a hint to an error message
addHint :: ErrorMessageHint -> MultipleErrors -> MultipleErrors
addHint hint = onErrorMessages $ \(ErrorMessage hints se) -> ErrorMessage (hint : hints) se

-- | The various types of things which might need to be relabelled in errors messages.
data LabelType = TypeLabel | SkolemLabel String deriving (Show, Read, Eq, Ord)

-- | A map from rigid type variable name/unknown variable pairs to new variables.
type UnknownMap = M.Map (LabelType, Unknown) Unknown

-- | How critical the issue is
data Level = Error | Warning deriving Show

-- |
-- Extract nested error messages from wrapper errors
--
unwrapErrorMessage :: ErrorMessage -> SimpleErrorMessage
unwrapErrorMessage (ErrorMessage _ se) = se

replaceUnknowns :: Type -> State UnknownMap Type
replaceUnknowns = everywhereOnTypesM replaceTypes
  where
  lookupTable :: (LabelType, Unknown) -> UnknownMap -> (Unknown, UnknownMap)
  lookupTable x m = case M.lookup x m of
                      Nothing -> let i = length (filter (on (==) fst x) (M.keys m)) in (i, M.insert x i m)
                      Just i  -> (i, m)

  replaceTypes :: Type -> State UnknownMap Type
  replaceTypes (TUnknown u) = state $ first TUnknown . lookupTable (TypeLabel, u)
  replaceTypes (Skolem name s sko) = state $ first (flip (Skolem name) sko) . lookupTable (SkolemLabel name, s)
  replaceTypes other = return other

onTypesInErrorMessageM :: (Applicative m) => (Type -> m Type) -> ErrorMessage -> m ErrorMessage
onTypesInErrorMessageM f (ErrorMessage hints simple) = ErrorMessage <$> traverse gHint hints <*> gSimple simple
  where
    gSimple (InfiniteType t) = InfiniteType <$> f t
    gSimple (TypesDoNotUnify t1 t2) = TypesDoNotUnify <$> f t1 <*> f t2
    gSimple (ConstrainedTypeUnified t1 t2) = ConstrainedTypeUnified <$> f t1 <*> f t2
    gSimple (ExprDoesNotHaveType e t) = ExprDoesNotHaveType e <$> f t
    gSimple (PropertyIsMissing s t) = PropertyIsMissing s <$> f t
    gSimple (CannotApplyFunction t e) = CannotApplyFunction <$> f t <*> pure e
    gSimple (InvalidInstanceHead t) = InvalidInstanceHead <$> f t
    gSimple other = pure other
    gHint (ErrorInSubsumption t1 t2) = ErrorInSubsumption <$> f t1 <*> f t2
    gHint (ErrorUnifyingTypes t1 t2) = ErrorUnifyingTypes <$> f t1 <*> f t2
    gHint (ErrorCheckingType e t) = ErrorCheckingType e <$> f t
    gHint (ErrorCheckingKind t) = ErrorCheckingKind <$> f t
    gHint (ErrorInApplication e1 t1 e2) = ErrorInApplication e1 <$> f t1 <*> pure e2
    gHint other = pure other

-- |
-- Pretty print a single error, simplifying if necessary
--
prettyPrintSingleError :: Bool -> Level -> ErrorMessage -> State UnknownMap Box.Box
prettyPrintSingleError full level e = prettyPrintErrorMessage . positionHintsFirst . reverseHints <$> onTypesInErrorMessageM replaceUnknowns (if full then e else simplifyErrorMessage e)
 where

  -- Pretty print an ErrorMessage
  prettyPrintErrorMessage :: ErrorMessage -> Box.Box
  prettyPrintErrorMessage (ErrorMessage hints simple) =
    paras $
      map renderHint hints ++
      renderSimpleErrorMessage simple :
      suggestions simple ++
      [line $ "See " ++ wikiUri ++ " for more information, or to contribute content related to this " ++ levelText ++ "."]
    where
    wikiUri :: String
    wikiUri = "https://github.com/purescript/purescript/wiki/Error-Code-" ++ errorCode e

    renderSimpleErrorMessage :: SimpleErrorMessage -> Box.Box
    renderSimpleErrorMessage (CannotGetFileInfo path) =
      paras [ line "Unable to read file info: "
            , indent . line $ path
            ]
    renderSimpleErrorMessage (CannotReadFile path) =
      paras [ line "Unable to read file: "
            , indent . line $ path
            ]
    renderSimpleErrorMessage (CannotWriteFile path) =
      paras [ line "Unable to write file: "
            , indent . line $ path
            ]
    renderSimpleErrorMessage (ErrorParsingExterns err) =
      paras [ lineWithLevel "parsing externs files: "
            , prettyPrintParseError err
            ]
    renderSimpleErrorMessage (ErrorParsingFFIModule path) =
      paras [ line "Unable to parse module from FFI file: "
            , indent . line $ path
            ]
    renderSimpleErrorMessage (ErrorParsingModule err) =
      paras [ line "Unable to parse module: "
            , prettyPrintParseError err
            ]
    renderSimpleErrorMessage (MissingFFIModule mn) =
      line $ "Missing FFI implementations for module " ++ runModuleName mn
    renderSimpleErrorMessage (UnnecessaryFFIModule mn path) =
      paras [ line $ "Unnecessary FFI implementations have been provided for module " ++ runModuleName mn ++ ": "
            , indent . line $ path
            ]
    renderSimpleErrorMessage (MultipleFFIModules mn paths) =
      paras [ line $ "Multiple FFI implementations have been provided for module " ++ runModuleName mn ++ ": "
            , indent . paras $ map line paths
            ]
    renderSimpleErrorMessage (InvalidExternsFile path) =
      paras [ line "Externs file is invalid: "
            , indent . line $ path
            ]
    renderSimpleErrorMessage InvalidDoBind =
      line "Bind statement cannot be the last statement in a do block. The last statement must be an expression."
    renderSimpleErrorMessage InvalidDoLet =
      line "Let statement cannot be the last statement in a do block. The last statement must be an expression."
    renderSimpleErrorMessage CannotReorderOperators =
      line "Unable to reorder operators"
    renderSimpleErrorMessage UnspecifiedSkolemScope =
      line "Skolem variable scope is unspecified"
    renderSimpleErrorMessage OverlappingNamesInLet =
      line "Overlapping names in let binding."
    renderSimpleErrorMessage (InfiniteType ty) =
      paras [ line "An infinite type was inferred for an expression: "
            , indent $ typeAsBox ty
            ]
    renderSimpleErrorMessage (InfiniteKind ki) =
      paras [ line "An infinite kind was inferred for a type: "
            , indent $ kindAsBox ki
            ]
    renderSimpleErrorMessage (MultipleFixities name) =
      line $ "Multiple fixity declarations for " ++ showIdent name
    renderSimpleErrorMessage (OrphanTypeDeclaration nm) =
      line $ "Orphan type declaration for " ++ showIdent nm
    renderSimpleErrorMessage (OrphanFixityDeclaration op) =
      line $ "Orphan fixity declaration for " ++ show op
    renderSimpleErrorMessage (RedefinedModule name filenames) =
      paras [ line ("Module " ++ runModuleName name ++ " has been defined multiple times:")
            , indent . paras $ map (line . displaySourceSpan) filenames
            ]
    renderSimpleErrorMessage (RedefinedIdent name) =
      line $ "Name " ++ showIdent name ++ " has been defined multiple times"
    renderSimpleErrorMessage (UnknownModule mn) =
      line $ "Unknown module " ++ runModuleName mn
    renderSimpleErrorMessage (UnknownType name) =
      line $ "Unknown type " ++ showQualified runProperName name
    renderSimpleErrorMessage (UnknownTypeClass name) =
      line $ "Unknown type class " ++ showQualified runProperName name
    renderSimpleErrorMessage (UnknownValue name) =
      line $ "Unknown value " ++ showQualified showIdent name
    renderSimpleErrorMessage (UnknownTypeConstructor name) =
      line $ "Unknown type constructor " ++ showQualified runProperName name
    renderSimpleErrorMessage (UnknownDataConstructor dc tc) =
      line $ "Unknown data constructor " ++ showQualified runProperName dc ++ foldMap ((" for type constructor " ++) . showQualified runProperName) tc
    renderSimpleErrorMessage (UnknownImportType mn name) =
      line $ "Module " ++ runModuleName mn ++ " does not export type " ++ runProperName name
    renderSimpleErrorMessage (UnknownExportType name) =
      line $ "Cannot export unknown type " ++ runProperName name
    renderSimpleErrorMessage (UnknownImportTypeClass mn name) =
      line $ "Module " ++ runModuleName mn ++ " does not export type class " ++ runProperName name
    renderSimpleErrorMessage (UnknownExportTypeClass name) =
      line $ "Cannot export unknown type class " ++ runProperName name
    renderSimpleErrorMessage (UnknownImportValue mn name) =
      line $ "Module " ++ runModuleName mn ++ " does not export value " ++ showIdent name
    renderSimpleErrorMessage (UnknownExportValue name) =
      line $ "Cannot export unknown value " ++ showIdent name
    renderSimpleErrorMessage (UnknownExportModule name) =
      line $ "Cannot export unknown module " ++ runModuleName name ++ ", it either does not exist or has not been imported by the current module"
    renderSimpleErrorMessage (UnknownImportDataConstructor mn tcon dcon) =
      line $ "Module " ++ runModuleName mn ++ " does not export data constructor " ++ runProperName dcon ++ " for type " ++ runProperName tcon
    renderSimpleErrorMessage (UnknownExportDataConstructor tcon dcon) =
      line $ "Cannot export data constructor " ++ runProperName dcon ++ " for type " ++ runProperName tcon ++ " as it has not been declared"
    renderSimpleErrorMessage (ConflictingImport nm mn) =
      line $ "Cannot declare " ++ show nm ++ " since another declaration of that name was imported from " ++ runModuleName mn
    renderSimpleErrorMessage (ConflictingImports nm m1 m2) =
      line $ "Conflicting imports for " ++ nm ++ " from modules " ++ runModuleName m1 ++ " and " ++ runModuleName m2
    renderSimpleErrorMessage (ConflictingTypeDecls nm) =
      line $ "Conflicting type declarations for " ++ runProperName nm
    renderSimpleErrorMessage (ConflictingCtorDecls nm) =
      line $ "Conflicting data constructor declarations for " ++ runProperName nm
    renderSimpleErrorMessage (TypeConflictsWithClass nm) =
      line $ "Type " ++ runProperName nm ++ " conflicts with type class declaration of the same name"
    renderSimpleErrorMessage (CtorConflictsWithClass nm) =
      line $ "Data constructor " ++ runProperName nm ++ " conflicts with type class declaration of the same name"
    renderSimpleErrorMessage (ClassConflictsWithType nm) =
      line $ "Type class " ++ runProperName nm ++ " conflicts with type declaration of the same name"
    renderSimpleErrorMessage (ClassConflictsWithCtor nm) =
      line $ "Type class " ++ runProperName nm ++ " conflicts with data constructor declaration of the same name"
    renderSimpleErrorMessage (DuplicateModuleName mn) =
      line $ "Module " ++ runModuleName mn ++ " has been defined multiple times."
    renderSimpleErrorMessage (DuplicateClassExport nm) =
      line $ "Duplicate export declaration for type class " ++ runProperName nm
    renderSimpleErrorMessage (DuplicateValueExport nm) =
      line $ "Duplicate export declaration for value " ++ showIdent nm
    renderSimpleErrorMessage (CycleInDeclaration nm) =
      line $ "Cycle in declaration of " ++ showIdent nm
    renderSimpleErrorMessage (CycleInModules mns) =
      line $ "Cycle in module dependencies: " ++ intercalate ", " (map runModuleName mns)
    renderSimpleErrorMessage (CycleInTypeSynonym pn) =
      line $ "Cycle in type synonym" ++ foldMap ((" " ++) . runProperName) pn
    renderSimpleErrorMessage (NameIsUndefined ident) =
      line $ showIdent ident ++ " is undefined"
    renderSimpleErrorMessage (NameNotInScope ident) =
      line $ showIdent ident ++ " may not be defined in the current scope"
    renderSimpleErrorMessage (UndefinedTypeVariable name) =
      line $ "Type variable " ++ runProperName name ++ " is undefined"
    renderSimpleErrorMessage (PartiallyAppliedSynonym name) =
      paras [ line $ "Partially applied type synonym " ++ showQualified runProperName name
            , line "Type synonyms must be applied to all of their type arguments."
            ]
    renderSimpleErrorMessage (EscapedSkolem binding) =
      paras $ [ line "A type variable has escaped its scope." ]
                     <> foldMap (\expr -> [ line "Relevant expression: "
                                          , indent $ prettyPrintValue expr
                                          ]) binding
    renderSimpleErrorMessage (TypesDoNotUnify t1 t2)
      = paras [ line "Cannot unify type"
              , indent $ typeAsBox t1
              , line "with type"
              , indent $ typeAsBox t2
              ]
    renderSimpleErrorMessage (KindsDoNotUnify k1 k2) =
      paras [ line "Cannot unify kind"
            , indent $ kindAsBox k1
            , line "with kind"
            , indent $ kindAsBox k2
            ]
    renderSimpleErrorMessage (ConstrainedTypeUnified t1 t2) =
      paras [ line "Cannot unify constrained type"
            , indent $ typeAsBox t1
            , line "with type"
            , indent $ typeAsBox t2
            ]
    renderSimpleErrorMessage (OverlappingInstances nm ts (d : ds)) =
      paras [ line "Overlapping instances found for"
            , indent $ Box.hsep 1 Box.left [ line (showQualified runProperName nm)
                                           , Box.vcat Box.left (map typeAtomAsBox ts)
                                           ]
            , line "The following instances were found:"
            , indent $ paras (line (showQualified showIdent d ++ " (chosen)") : map (line . showQualified showIdent) ds)
            ]
    renderSimpleErrorMessage OverlappingInstances{} = error "OverlappingInstances: empty instance list"
    renderSimpleErrorMessage (NoInstanceFound nm ts) =
      paras [ line "No instance found for"
            , indent $ Box.hsep 1 Box.left [ line (showQualified runProperName nm)
                                           , Box.vcat Box.left (map typeAtomAsBox ts)
                                           ]
            ]
    renderSimpleErrorMessage (PossiblyInfiniteInstance nm ts) =
      paras [ line "Instance for"
            , indent $ Box.hsep 1 Box.left [ line (showQualified runProperName nm)
                                           , Box.vcat Box.left (map typeAtomAsBox ts)
                                           ]
            , line "is possibly infinite."
            ]
    renderSimpleErrorMessage (CannotDerive nm ts) =
      paras [ line "Cannot derive an instance for"
            , indent $ Box.hsep 1 Box.left [ line (showQualified runProperName nm)
                                           , Box.vcat Box.left (map typeAtomAsBox ts)
                                           ]
            ]
    renderSimpleErrorMessage (CannotFindDerivingType nm) =
      line $ "Cannot derive instance, because the type declaration for " ++ runProperName nm ++ " could not be found."
    renderSimpleErrorMessage (DuplicateLabel l expr) =
      paras $ [ line $ "Duplicate label " ++ show l ++ " in row." ]
                       <> foldMap (\expr' -> [ line "Relevant expression: "
                                             , indent $ prettyPrintValue expr'
                                             ]) expr
    renderSimpleErrorMessage (DuplicateTypeArgument name) =
      line $ "Duplicate type argument " ++ show name
    renderSimpleErrorMessage (DuplicateValueDeclaration nm) =
      line $ "Duplicate value declaration for " ++ showIdent nm
    renderSimpleErrorMessage (ArgListLengthsDiffer ident) =
      line $ "Argument list lengths differ in declaration " ++ showIdent ident
    renderSimpleErrorMessage (OverlappingArgNames ident) =
      line $ "Overlapping names in function/binder" ++ foldMap ((" in declaration" ++) . showIdent) ident
    renderSimpleErrorMessage (MissingClassMember ident) =
      line $ "Member " ++ showIdent ident ++ " has not been implemented"
    renderSimpleErrorMessage (ExtraneousClassMember ident) =
      line $ "Member " ++ showIdent ident ++ " is not a member of the class being instantiated"
    renderSimpleErrorMessage (ExpectedType ty kind) =
      paras [ line "In a type-annotated expression x :: t, the type t must have kind *."
            , line "The error arises from the type"
            , indent $ typeAsBox ty
            , line "having the kind"
            , indent $ kindAsBox kind
            , line "instead."
            ]
    renderSimpleErrorMessage (IncorrectConstructorArity nm) =
      line $ "Wrong number of arguments to constructor " ++ showQualified runProperName nm
    renderSimpleErrorMessage SubsumptionCheckFailed = line "Unable to check type subsumption"
    renderSimpleErrorMessage (ExprDoesNotHaveType expr ty) =
      paras [ line "Expression"
            , indent $ prettyPrintValue expr
            , line "does not have type"
            , indent $ typeAsBox ty
            ]
    renderSimpleErrorMessage (PropertyIsMissing prop row) =
      paras [ line "Row"
            , indent $ prettyPrintRowWith '(' ')' row
            , line $ "lacks required property " ++ show prop
            ]
    renderSimpleErrorMessage (CannotApplyFunction fn arg) =
      paras [ line "Cannot apply function of type"
            , indent $ typeAsBox fn
            , line "to argument"
            , indent $ prettyPrintValue arg
            ]
    renderSimpleErrorMessage TypeSynonymInstance =
      line "Type synonym instances are disallowed"
    renderSimpleErrorMessage (OrphanInstance nm cnm ts) =
      paras [ line $ "Instance " ++ showIdent nm ++ " for "
            , indent $ Box.hsep 1 Box.left [ line (showQualified runProperName cnm)
                                           , Box.vcat Box.left (map typeAtomAsBox ts)
                                           ]
            , line "is an orphan instance."
            , line "An orphan instance is an instance which is defined in neither the class module nor the data type module."
            , line "Consider moving the instance, if possible, or using a newtype wrapper."
            ]
    renderSimpleErrorMessage InvalidNewtype =
      line "Newtypes must define a single constructor with a single argument"
    renderSimpleErrorMessage (InvalidInstanceHead ty) =
      paras [ line "Invalid type in class instance head:"
            , indent $ typeAsBox ty
            ]
    renderSimpleErrorMessage (TransitiveExportError x ys) =
      paras $ line ("An export for " ++ prettyPrintExport x ++ " requires the following to also be exported: ")
              : map (line . prettyPrintExport) ys
    renderSimpleErrorMessage (ShadowedName nm) =
      line $ "Name '" ++ showIdent nm ++ "' was shadowed"
    renderSimpleErrorMessage (ShadowedTypeVar tv) =
      line $ "Type variable '" ++ tv ++ "' was shadowed"
    renderSimpleErrorMessage (UnusedTypeVar tv) =
      line $ "Type variable '" ++ tv ++ "' was declared but not used"
    renderSimpleErrorMessage (ClassOperator className opName) =
      paras [ line $ "Class '" ++ runProperName className ++ "' declares operator " ++ showIdent opName ++ "."
            , line "This may be disallowed in the future - consider declaring a named member in the class and making the operator an alias:"
            , indent . line $ showIdent opName ++ " = someMember"
            ]
    renderSimpleErrorMessage (MisleadingEmptyTypeImport mn name) =
      line $ "Importing type " ++ runProperName name ++ "(..) from " ++ runModuleName mn ++ " is misleading as it has no exported data constructors"
    renderSimpleErrorMessage (ImportHidingModule name) =
      line $ "Attempted to hide module " ++ runModuleName name ++ " in import expression, this is not permitted"
    renderSimpleErrorMessage (WildcardInferredType ty) =
      paras [ line "The wildcard type definition has the inferred type "
            , indent $ typeAsBox ty
            ]
    renderSimpleErrorMessage (MissingTypeDeclaration ident) =
      paras [ line $ "No type declaration was provided for the top-level declaration of " ++ showIdent ident ++ "."
            , line "It is good practice to provide type declarations as a form of documentation."
            , line "Consider using a type wildcard to display the inferred type:"
            , indent $ line $ showIdent ident ++ " :: _"
            ]
    renderSimpleErrorMessage (NotExhaustivePattern bs b) =
      paras $ [ line "A case expression could not be determined to cover all inputs."
              , line "The following additional cases are required to cover all inputs:\n"
              , Box.hsep 1 Box.left (map (paras . map (line . prettyPrintBinderAtom)) (transpose bs))
              ] ++
              [ line "..." | not b ]
    renderSimpleErrorMessage (OverlappingPattern bs b) =
      paras $ [ line "A case expression contains unreachable cases:\n"
              , Box.hsep 1 Box.left (map (paras . map (line . prettyPrintBinderAtom)) (transpose bs))
              ] ++
              [ line "..." | not b ]
    renderSimpleErrorMessage IncompleteExhaustivityCheck =
      paras [ line "An exhaustivity check was abandoned due to too many possible cases."
            , line "You may want to decomposing your data types into smaller types."
            ]

    renderHint :: ErrorMessageHint -> Box.Box
    renderHint (NotYetDefined names) =
      line $ "The following are not yet defined here: " ++ intercalate ", " (map showIdent names) ++ ":"
    renderHint (ErrorUnifyingTypes t1 t2) =
      paras [ lineWithLevel "unifying type "
            , indent $ typeAsBox t1
            , line "with type"
            , indent $ typeAsBox t2
            ]
    renderHint (ErrorInExpression expr) =
      paras [ lineWithLevel "in expression:"
            , indent $ prettyPrintValue expr
            ]
    renderHint (ErrorInModule mn) =
      paras [ lineWithLevel $ "in module " ++ runModuleName mn ++ ":"
            ]
    renderHint (ErrorInSubsumption t1 t2) =
      paras [ lineWithLevel "checking that type "
            , indent $ typeAsBox t1
            , line "subsumes type"
            , indent $ typeAsBox t2
            ]
    renderHint (ErrorInInstance nm ts) =
      paras [ lineWithLevel "in type class instance"
            , indent $ Box.hsep 1 Box.left [ line (showQualified runProperName nm)
                                           , Box.vcat Box.left (map typeAtomAsBox ts)
                                           ]
            ]
    renderHint (ErrorCheckingKind ty) =
      paras [ lineWithLevel "checking kind of type "
            , indent $ typeAsBox ty
            ]
    renderHint (ErrorInferringType expr) =
      paras [ lineWithLevel "inferring type of value "
            , indent $ prettyPrintValue expr
            ]
    renderHint (ErrorCheckingType expr ty) =
      paras [ lineWithLevel "checking that value "
            , indent $ prettyPrintValue expr
            , line "has type"
            , indent $ typeAsBox ty
            ]
    renderHint (ErrorInApplication f t a) =
      paras [ lineWithLevel "applying function"
            , indent $ prettyPrintValue f
            , line "of type"
            , indent $ typeAsBox t
            , line "to argument"
            , indent $ prettyPrintValue a
            ]
    renderHint (ErrorInDataConstructor nm) =
      lineWithLevel $ "in data constructor " ++ runProperName nm ++ ":"
    renderHint (ErrorInTypeConstructor nm) =
      lineWithLevel $ "in type constructor " ++ runProperName nm ++ ":"
    renderHint (ErrorInBindingGroup nms) =
      lineWithLevel $ "in binding group " ++ intercalate ", " (map showIdent nms) ++ ":"
    renderHint ErrorInDataBindingGroup =
      lineWithLevel "in data binding group:"
    renderHint (ErrorInTypeSynonym name) =
      lineWithLevel $ "in type synonym " ++ runProperName name ++ ":"
    renderHint (ErrorInValueDeclaration n) =
      lineWithLevel $ "in value declaration " ++ showIdent n ++ ":"
    renderHint (ErrorInTypeDeclaration n) =
      lineWithLevel $ "in type declaration for " ++ showIdent n ++ ":"
    renderHint (ErrorInForeignImport nm) =
      lineWithLevel $ "in foreign import " ++ showIdent nm ++ ":"
    renderHint (PositionedError srcSpan) =
      lineWithLevel $ "at " ++ displaySourceSpan srcSpan ++ ":"

  lineWithLevel :: String -> Box.Box
  lineWithLevel text = line $ show level ++ " " ++ text

  levelText :: String
  levelText = case level of
    Error -> "error"
    Warning -> "warning"

  suggestions :: SimpleErrorMessage -> [Box.Box]
  suggestions (ConflictingImport nm im) = [ line $ "Possible fix: hide " ++ show nm ++ " when importing " ++ runModuleName im ++ ":"
                                             , indent . line $ "import " ++ runModuleName im ++ " hiding (" ++ nm ++ ")"
                                             ]
  suggestions (TypesDoNotUnify t1 t2)
    | isObject t1 && isFunction t2 = [line "Note that function composition in PureScript is defined using (<<<)"]
    | otherwise             = []
  suggestions _ = []

  paras :: [Box.Box] -> Box.Box
  paras = Box.vcat Box.left

  -- Pretty print and export declaration
  prettyPrintExport :: DeclarationRef -> String
  prettyPrintExport (TypeRef pn _) = runProperName pn
  prettyPrintExport (ValueRef ident) = showIdent ident
  prettyPrintExport (TypeClassRef pn) = runProperName pn
  prettyPrintExport (TypeInstanceRef ident) = showIdent ident
  prettyPrintExport (ModuleRef name) = "module " ++ runModuleName name
  prettyPrintExport (PositionedDeclarationRef _ _ ref) = prettyPrintExport ref

  -- Hints get added at the front, so we need to reverse them before rendering
  reverseHints :: ErrorMessage -> ErrorMessage
  reverseHints (ErrorMessage hints simple) = ErrorMessage (reverse hints) simple

  -- | Put positional hints at the front of the list
  positionHintsFirst :: ErrorMessage -> ErrorMessage
  positionHintsFirst (ErrorMessage hints simple) = ErrorMessage (uncurry (++) $ partition (isPositionHint . hintCategory) hints) simple
    where
    isPositionHint :: HintCategory -> Bool
    isPositionHint PositionHint = True
    isPositionHint OtherHint = True
    isPositionHint _ = False

  -- | Simplify an error message
  simplifyErrorMessage :: ErrorMessage -> ErrorMessage
  simplifyErrorMessage (ErrorMessage hints simple) = ErrorMessage (simplifyHints hints) simple
    where
    -- Take the last instance of each "hint category"
    simplifyHints :: [ErrorMessageHint] -> [ErrorMessageHint]
    simplifyHints = reverse . nubBy categoriesEqual . reverse

    -- Don't remove hints in the "other" category
    categoriesEqual :: ErrorMessageHint -> ErrorMessageHint -> Bool
    categoriesEqual x y =
      case (hintCategory x, hintCategory y) of
        (OtherHint, _) -> False
        (_, OtherHint) -> False
        (c1, c2) -> c1 == c2

  hintCategory :: ErrorMessageHint -> HintCategory
  hintCategory ErrorCheckingType{}  = ExprHint
  hintCategory ErrorInferringType{} = ExprHint
  hintCategory ErrorInExpression{}  = ExprHint
  hintCategory ErrorUnifyingTypes{} = CheckHint
  hintCategory ErrorInSubsumption{} = CheckHint
  hintCategory ErrorInApplication{} = CheckHint
  hintCategory PositionedError{}    = PositionHint
  hintCategory _                    = OtherHint

-- |
-- Pretty print multiple errors
--
prettyPrintMultipleErrors :: Bool -> MultipleErrors -> String
prettyPrintMultipleErrors full = renderBox . prettyPrintMultipleErrorsBox full

-- |
-- Pretty print multiple warnings
--
prettyPrintMultipleWarnings :: Bool -> MultipleErrors ->  String
prettyPrintMultipleWarnings full = renderBox . prettyPrintMultipleWarningsBox full

-- | Pretty print warnings as a Box
prettyPrintMultipleWarningsBox :: Bool -> MultipleErrors -> Box.Box
prettyPrintMultipleWarningsBox full = flip evalState M.empty . prettyPrintMultipleErrorsWith Warning "Warning found:" "Warning" full

-- | Pretty print errors as a Box
prettyPrintMultipleErrorsBox :: Bool -> MultipleErrors -> Box.Box
prettyPrintMultipleErrorsBox full = flip evalState M.empty . prettyPrintMultipleErrorsWith Error "Error found:" "Error" full

prettyPrintMultipleErrorsWith :: Level -> String -> String -> Bool -> MultipleErrors -> State UnknownMap Box.Box
prettyPrintMultipleErrorsWith level intro _ full  (MultipleErrors [e]) = do
  result <- prettyPrintSingleError full level e
  return $
    Box.vcat Box.left [ Box.text intro
                      , result
                      ]
prettyPrintMultipleErrorsWith level _ intro full  (MultipleErrors es) = do
  result <- forM es $ prettyPrintSingleError full level
  return $ Box.vsep 1 Box.left $ concat $ zipWith withIntro [1 :: Int ..] result
  where
  withIntro i err = [ Box.text (intro ++ " " ++ show i ++ " of " ++ show (length es) ++ ":")
                    , Box.moveRight 2 err
                    ]

-- | Pretty print a Parsec ParseError as a Box
prettyPrintParseError :: P.ParseError -> Box.Box
prettyPrintParseError = prettyPrintParseErrorMessages "or" "unknown parse error" "expecting" "unexpected" "end of input" . PE.errorMessages

-- |
-- Pretty print ParseError detail messages.
--
-- Adapted from 'Text.Parsec.Error.showErrorMessages', see <https://github.com/aslatter/parsec/blob/v3.1.9/Text/Parsec/Error.hs#L173>.
--
prettyPrintParseErrorMessages :: String -> String -> String -> String -> String -> [Message] -> Box.Box
prettyPrintParseErrorMessages msgOr msgUnknown msgExpecting msgUnExpected msgEndOfInput msgs
  | null msgs = Box.text msgUnknown
  | otherwise = Box.vcat Box.left $ map Box.text $ clean [showSysUnExpect,showUnExpect,showExpect,showMessages]

  where
  (sysUnExpect,msgs1) = span (SysUnExpect "" ==) msgs
  (unExpect,msgs2)    = span (UnExpect    "" ==) msgs1
  (expect,messages)   = span (Expect      "" ==) msgs2

  showExpect      = showMany msgExpecting expect
  showUnExpect    = showMany msgUnExpected unExpect
  showSysUnExpect | not (null unExpect) ||
                    null sysUnExpect = ""
                  | null firstMsg    = msgUnExpected ++ " " ++ msgEndOfInput
                  | otherwise        = msgUnExpected ++ " " ++ firstMsg
    where
    firstMsg  = PE.messageString (head sysUnExpect)

  showMessages      = showMany "" messages

  -- helpers
  showMany pre msgs' = case clean (map PE.messageString msgs') of
                         [] -> ""
                         ms | null pre  -> commasOr ms
                            | otherwise -> pre ++ " " ++ commasOr ms

  commasOr []       = ""
  commasOr [m]      = m
  commasOr ms       = commaSep (init ms) ++ " " ++ msgOr ++ " " ++ last ms

  commaSep          = separate ", " . clean

  separate   _ []     = ""
  separate   _ [m]    = m
  separate sep (m:ms) = m ++ sep ++ separate sep ms

  clean             = nub . filter (not . null)

-- | Indent to the right, and pad on top and bottom.
indent :: Box.Box -> Box.Box
indent = Box.moveUp 1 . Box.moveDown 1 . Box.moveRight 2

line :: String -> Box.Box
line = Box.text

renderBox :: Box.Box -> String
renderBox = unlines . map trimEnd . lines . Box.render
  where
  trimEnd = reverse . dropWhile (== ' ') . reverse

-- |
-- Interpret multiple errors and warnings in a monad supporting errors and warnings
--
interpretMultipleErrorsAndWarnings :: (MonadError MultipleErrors m, MonadWriter MultipleErrors m) => (Either MultipleErrors a, MultipleErrors) -> m a
interpretMultipleErrorsAndWarnings (err, ws) = do
  tell ws
  either throwError return err

-- |
-- Rethrow an error with a more detailed error message in the case of failure
--
rethrow :: (MonadError e m) => (e -> e) -> m a -> m a
rethrow f = flip catchError $ \e -> throwError (f e)

warnAndRethrow :: (MonadError e m, MonadWriter e m) => (e -> e) -> m a -> m a
warnAndRethrow f = rethrow f . censor f

-- |
-- Rethrow an error with source position information
--
rethrowWithPosition :: (MonadError MultipleErrors m) => SourceSpan -> m a -> m a
rethrowWithPosition pos = rethrow (onErrorMessages (withPosition pos))

warnWithPosition :: (MonadWriter MultipleErrors m) => SourceSpan -> m a -> m a
warnWithPosition pos = censor (onErrorMessages (withPosition pos))

warnAndRethrowWithPosition :: (MonadError MultipleErrors m, MonadWriter MultipleErrors m) => SourceSpan -> m a -> m a
warnAndRethrowWithPosition pos = rethrowWithPosition pos . warnWithPosition pos

withPosition :: SourceSpan -> ErrorMessage -> ErrorMessage
withPosition pos (ErrorMessage hints se) = ErrorMessage (PositionedError pos : hints) se

-- |
-- Collect errors in in parallel
--
parU :: (MonadError MultipleErrors m, Functor m) => [a] -> (a -> m b) -> m [b]
parU xs f = forM xs (withError . f) >>= collectErrors
  where
  withError :: (MonadError MultipleErrors m, Functor m) => m a -> m (Either MultipleErrors a)
  withError u = catchError (Right <$> u) (return . Left)

  collectErrors :: (MonadError MultipleErrors m, Functor m) => [Either MultipleErrors a] -> m [a]
  collectErrors es = case lefts es of
    [] -> return $ rights es
    errs -> throwError $ fold errs
