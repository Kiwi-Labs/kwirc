module ParseDec
	(parseDec)
where

import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Char (isAlpha, isDigit)
import Control.Monad (guard)

import Syntax
import Parse
import ParseSpace
import ParseIdent
import ParseType
import ParseStat
import ParseExpr

-- This was copied-and-pasted from ParseStat.
-- It's very small, but maybe it should be refactored into some common module?
semicolon :: Parse Char ()
semicolon = optional kspace >> lit ';' >> return ()

parseAccessModifier :: Parse Char Access
parseAccessModifier = greedy $ parseEither
	(lits "publ" >> kspace >> return Public)
	(return Private)

data ComplexAccessModifier = PublicWithExclusions (Set.Set String) | PrivateComplex

parseAccessExclusionOption :: Parse Char String
parseAccessExclusionOption = greedy $ many $ choice [litCond isAlpha, litCond isDigit, lit '_']

parseComplexAccessModifier :: Parse Char ComplexAccessModifier
parseComplexAccessModifier = greedy $ parseEither public (return PrivateComplex) where
	public = do
		lits "publ"
		exclusions <- parseEither parseExclusions (kspace >> return Set.empty)
		optional kspace
		return $ PublicWithExclusions exclusions
	parseExclusions = do
		optional kspace
		lit '('
		optional kspace
		lits "priv"
		kspace
		options <- kcommaSeparated $ parseAccessExclusionOption
		guard $ not $ null options
		optional kspace
		lit ')'
		return $ Set.fromList options

parseArgDef :: Parse Char ArgumentDef
parseArgDef = greedy $ do
	mode <- parseEither (lit '#' >> optional kspace >> return NamedArg) (return PositionalArg)
	name <- parseLocalIdent
	optional kspace
	lit ':'
	optional kspace
	t <- parseType
	return $ ArgumentDef mode name t

parseArgDefList :: Parse Char [ArgumentDef]
parseArgDefList = kparenthesized parseArgDef

parseRetTypes :: Parse Char [Type]
parseRetTypes = fmap (fromMaybe []) $ greedy $ optional $ do
		optional kspace
		lits "->"
		optional kspace
		kparenthesized parseType

parseFuncDec :: Parse Char Dec
parseFuncDec = greedy $ do
	access <- parseAccessModifier
	lits "func"
	kspace
	name <- parseUnresolvedIdent
	optional kspace
	args <- parseArgDefList
	retTypes <- parseRetTypes
	optional kspace
	body <- parseBody
	return $ FuncDec access name args retTypes body

parseSpecialArg :: Parse Char SpecialArgument
parseSpecialArg = greedy $ do
	lit '('
	optional kspace
	name <- parseLocalIdent
	optional kspace
	lit ':'
	optional kspace
	t <- parseType
	optional kspace
	lit ')'
	return $ SpecialArgument name t

parseGetterDec :: Parse Char Dec
parseGetterDec = greedy $ do
	access <- parseAccessModifier
	lits "getter"
	optional kspace
	receiver <- parseSpecialArg
	optional kspace
	lit '.'
	optional kspace
	name <- parseUnresolvedIdent
	args <- fmap (fromMaybe []) $ optional (optional kspace >> parseArgDefList)
	optional kspace
	lits "->"
	optional kspace
	t <- parseType
	optional kspace
	body <- parseBody
	return $ GetterDec access name receiver args t body

parseSetterDec :: Parse Char Dec
parseSetterDec = greedy $ do
	access <- parseAccessModifier
	setterMode <- parseEither
		(lits "constr" >> return ConstructiveSetter)
		(lits "destr"  >> return DestructiveSetter)
	kspace
	lits "setter"
	optional kspace
	receiver <- parseSpecialArg
	optional kspace
	lit '.'
	optional kspace
	name <- parseUnresolvedIdent
	args <- fmap (fromMaybe []) $ optional (optional kspace >> parseArgDefList)
	optional kspace
	lit '='
	optional kspace
	newValArg <- parseSpecialArg
	optional kspace
	body <- parseBody
	return $ SetterDec access setterMode name receiver args newValArg body

parseMethodDec :: Parse Char Dec
parseMethodDec = greedy $ do
	access <- parseAccessModifier
	lits "method"
	kspace
	name <- parseUnresolvedIdent
	optional kspace
	lit '('
	optional kspace
	lits "dynamic"
	kspace
	dynArg <- parseArgDef
	mainArgs <- fmap (fromMaybe []) $ optional $ greedy $ do
		optional kspace
		lit ','
		optional kspace
		kcommaSeparated parseArgDef
	optional kspace
	lit ')'
	retTypes <- parseRetTypes
	optional kspace
	body <- parseBody
	return $ MethodDec access name dynArg mainArgs retTypes body
	

parseStructCaseAccess :: Parse Char StructCaseAccess
parseStructCaseAccess = greedy $ do
	rawOptions <- parseComplexAccessModifier
	case rawOptions of
		PublicWithExclusions exclusions -> do
			guard $ Set.fromList ["make"] >= exclusions
			let constructorAccess = if Set.member "make" exclusions
				then PrivateConstructor
				else PublicConstructor
			return $ PublicCase constructorAccess
		PrivateComplex -> return PrivateCase

parseFieldAccess :: Parse Char (GetterAccess, SetterAccess)
parseFieldAccess = greedy $ do
	rawOptions <- parseComplexAccessModifier
	case rawOptions of
		PublicWithExclusions exclusions -> case Set.toList exclusions of
			["getter"] -> return (PrivateGetter, PublicSetter)
			["setter"] -> return (PublicGetter, PrivateSetter)
			[] -> return (PublicGetter, PublicSetter)
			_ -> parseFailure
		PrivateComplex -> return (PrivateGetter, PrivateSetter)

-- This function should probably be refactored into some
-- utility file
partitionWith :: (x -> Either a b) -> [x] -> ([a], [b])
partitionWith _ [] = ([], [])
partitionWith f (x : xs) =
	let (as, bs) = partitionWith f xs
	in case f x of
		Left a  -> (a : as, bs)
		Right b -> (as, b : bs)

parseFieldContent :: Parse Char FieldContent
parseFieldContent = greedy $ parseEither initializer fieldType where
	initializer = do
		lit '='
		optional kspace
		expr <- parseExpr
		return $ FieldInitializer expr
	fieldType = do
		lit ':'
		optional kspace
		t <- parseType
		return $ FieldType t

parseField :: Parse Char Field
parseField = greedy $ do
	(getterAccess, setterAccess) <- parseFieldAccess
	mode <- parseEither (lits "var" >> return VarBinding) (lits "let" >> return LetBinding)
	kspace
	name <- parseLocalIdent
	optional kspace
	content <- parseFieldContent
	semicolon
	return $ Field getterAccess setterAccess mode name content

parseStructSubcase :: Parse Char (LocalIdent, StructCase)
parseStructSubcase = greedy $ do
	access <- parseStructCaseAccess
	lits "case"
	kspace
	name <- parseLocalIdent
	optional kspace
	(fields, subCases) <- parseEither
		parseStructCaseBody
		(semicolon >> return ([], []))
	return $ (name, StructCase access fields subCases)

parseStructElement :: Parse Char (Either Field (LocalIdent, StructCase))
parseStructElement = parseEither
	(fmap Left parseField)
	(fmap Right parseStructSubcase)

parseStructCaseBody :: Parse Char ([Field], [(LocalIdent, StructCase)])
parseStructCaseBody = greedy $ do
	lit '{'
	elements <- greedyMany $ do
		optional kspace
		parseStructElement
	optional kspace
	lit '}'
	return $ partitionWith id elements

parseStructDec :: Parse Char Dec
parseStructDec = greedy $ do
	access <- parseStructCaseAccess
	lits "struct"
	kspace
	name <- parseLocalIdent
	optional kspace
	(fields, subCases) <- parseStructCaseBody
	return $ StructDec name $ StructCase access fields subCases

parseDec :: Parse Char Dec
parseDec = choice
	[parseFuncDec
	,parseStructDec
	,parseGetterDec
	,parseSetterDec
	,parseMethodDec]
