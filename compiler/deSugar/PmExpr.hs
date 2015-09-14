
{-
  Author: George Karachalias <george.karachalias@cs.kuleuven.be>
-}

{-# OPTIONS_GHC -Wwarn #-}   -- unused variables
{-# LANGUAGE CPP #-}

module PmExpr (
        -- Types
        PmExpr(..), PmLit(..), PmNegLitCt,
        VarEq, SimpleEq, ComplexEq,

        -- Partition term equalities
        partitionSimple, partitionComplex,

        -- Predicates
        isTruePmExpr, isFalsePmExpr, isNotPmExprOther,

        -- Substitution in PmExpr
        substSimpleEqs, substComplexEq,
        idSubstVarEq, idSubstSimpleEq, idSubstComplexEq,

        -- Lift (HsExpr Id) to PmExpr
        hsExprToPmExpr, lhsExprToPmExpr,

        -- Pretty printing
        filterComplex, runPmPprM, pprPmExprWithParens,

        -- Misc
        truePmExpr, falsePmExpr, toComplex, pmLitType
    ) where

#include "HsVersions.h"

import Type
import TcHsSyn
import HsSyn
import Id
import DataCon
import TysWiredIn
import Outputable
import Util
import MonadUtils
import SrcLoc
import BasicTypes (boxityNormalTupleSort)
import FastString -- sLit
import VarSet

import Control.Arrow (first)
import Data.Maybe (mapMaybe)
import Data.List (groupBy, sortBy, nub)
import Control.Monad.Trans.State.Lazy

{-
%************************************************************************
%*                                                                      *
\subsection{The term equality oracle}
%*                                                                      *
%************************************************************************

-- NOTE [Term oracle strategy]

Because of the incremental nature of the algorithm, initially all constraints
are shallow and most of them are simple equalities between variables. In
general, even if we start only with equalities of the form (x ~ e), the oracle
distinguishes between equalities of 3 different forms:

  * Variable equalities (VE) of the form (x ~ y)
  * Simple   equalities (SE) of the form (x ~ e)
  * Complex  equalities (CE) of the form (e ~ e')

The overall strategy works in 2 phases:

A. Preparation Phase
====================
1) Partition initial set into VE and 'actual simples' SE (partitionSimple).
2) Solve VE (solveVarEqs) and apply the resulting substitution in SE.
3) Repeatedly apply [x |-> e] to SE, as long as a simple equality (x ~ e)
   exists in it (eliminateSimples). The result is a set of 'actual' complex
   equalities CE.

Steps (1),(2),(3) are all performed by `prepComplexEq' on CE, which is the
most general form of equality.

B. Solving Phase
================
1) Try to simplify the constraints by means of flattening, evaluation of
   expressions etc. (simplifyComplexEqs).
2) If some simplification happens, prepare the constraints (prepComplexEq) and
   repeat the Solving Phase.

-}

-- ----------------------------------------------------------------------------
-- | Datatype PmExpr

data PmExpr = PmExprVar   Id
            | PmExprCon   DataCon [PmExpr]
            | PmExprLit   PmLit
            | PmExprEq    PmExpr PmExpr  -- Syntactic equality
            | PmExprOther (HsExpr Id)    -- NOTE [PmExprOther in PmExpr]

data PmLit = PmSLit HsLit                                    -- simple
           | PmOLit Bool {- is it negated? -} (HsOverLit Id) -- overloaded

instance Eq PmLit where
  PmSLit    l1 == PmSLit l2    = l1 == l2
  PmOLit b1 l1 == PmOLit b2 l2 = b1 == b2 && l1 == l2
  _ == _ = False

-- ----------------------------------------------------------------------------
-- | Term equalities

type VarEq     = (Id, Id)
type SimpleEq  = (Id, PmExpr) -- We always use this orientation
type ComplexEq = (PmExpr, PmExpr)

-- ----------------------------------------------------------------------------
-- | Utilities

-- Expressions `True' and `False'
truePmExpr :: PmExpr
truePmExpr = PmExprCon trueDataCon []

falsePmExpr :: PmExpr
falsePmExpr = PmExprCon falseDataCon []

pmLitType :: PmLit -> Type
pmLitType (PmSLit   lit) = hsLitType   lit
pmLitType (PmOLit _ lit) = overLitType lit

-- | Not actually a ComplexEq, we just wrap it with a PmExprVar
toComplex :: SimpleEq -> ComplexEq
toComplex = first PmExprVar

-- ----------------------------------------------------------------------------
-- | Partitioning equalities (VarEq, SimpleEq, ComplexEq and Unhandled Eqs)

partitionSimple :: [SimpleEq] -> ([VarEq], [SimpleEq], [SimpleEq])
partitionSimple in_cs = foldr select ([],[],[]) in_cs
  where
    select eq@(x,e) ~(var_eqs, other_eqs, res_eqs)
      | PmExprVar y   <- e = ((x,y):var_eqs,    other_eqs,    res_eqs)
      | PmExprOther _ <- e = (      var_eqs,    other_eqs, eq:res_eqs)
      | otherwise          = (      var_eqs, eq:other_eqs,    res_eqs)

partitionComplex :: [ComplexEq] -> ([VarEq], [SimpleEq], [ComplexEq], [SimpleEq])
partitionComplex in_cs = foldr select ([],[],[],[]) in_cs
  where
    select eq@(e1,e2) ~(var_eqs, simpl_eqs, other_eqs, res_eqs)
      | PmExprVar x <- e1 = selectSimple x e2 (var_eqs, simpl_eqs, other_eqs, res_eqs)
      | PmExprVar y <- e2 = selectSimple y e1 (var_eqs, simpl_eqs, other_eqs, res_eqs)
      | otherwise         = (var_eqs, simpl_eqs, eq:other_eqs, res_eqs)

    selectSimple x e ~(var_eqs, simpl_eqs, other_eqs, res_eqs)
      | PmExprVar y   <- e = ((x,y):var_eqs,       simpl_eqs, other_eqs,       res_eqs)
      | PmExprOther _ <- e = (      var_eqs,       simpl_eqs, other_eqs, (x,e):res_eqs)
      | otherwise          = (      var_eqs, (x,e):simpl_eqs, other_eqs,       res_eqs)

-- ----------------------------------------------------------------------------
-- | Predicates

-- | Check if an expression is lifted or not
isNotPmExprOther :: PmExpr -> Bool
isNotPmExprOther (PmExprOther _) = False
isNotPmExprOther _expr           = True

-- | Check whether a literal is negated
isNegatedPmLit :: PmLit -> Bool
isNegatedPmLit (PmOLit b _) = b
isNegatedPmLit _other_lit   = False

-- | Check whether a PmExpr is equal to term `True' (syntactically).
isTruePmExpr :: PmExpr -> Bool
isTruePmExpr (PmExprCon c []) = c == trueDataCon
isTruePmExpr _other_expr      = False

-- | Check whether a PmExpr is equal to term `False' (syntactically).
isFalsePmExpr :: PmExpr -> Bool
isFalsePmExpr (PmExprCon c []) = c == falseDataCon
isFalsePmExpr _other_expr      = False

isNilPmExpr :: PmExpr -> Bool
isNilPmExpr (PmExprCon c _) = c == nilDataCon
isNilPmExpr _other_expr     = False

isPmExprEq :: PmExpr -> Maybe (PmExpr, PmExpr)
isPmExprEq (PmExprEq e1 e2) = Just (e1,e2)
isPmExprEq _other_expr      = Nothing

isConsDataCon :: DataCon -> Bool
isConsDataCon con = consDataCon == con

-- ----------------------------------------------------------------------------
-- | Substitution in PmExpr

substPmExpr :: Id -> PmExpr -> PmExpr -> PmExpr
substPmExpr x e1 e =
  case e of
    PmExprVar z | x == z    -> e1
                | otherwise -> e
    PmExprCon c ps -> PmExprCon c (map (substPmExpr x e1) ps)
    PmExprEq ex ey -> PmExprEq (substPmExpr x e1 ex) (substPmExpr x e1 ey)
    _other_expr    -> e -- The rest are terminals -- we silently ignore
                        -- PmExprOther. See NOTE [PmExprOther in PmExpr]

idSubstPmExpr :: (Id -> Id) -> PmExpr -> PmExpr
idSubstPmExpr fn e =
  case e of
    PmExprVar z    -> PmExprVar (fn z)
    PmExprCon c es -> PmExprCon c (map (idSubstPmExpr fn) es)
    PmExprEq e1 e2 -> PmExprEq (idSubstPmExpr fn e1) (idSubstPmExpr fn e2)
    _other_expr    -> e -- The rest are terminals -- we silently ignore
                        -- PmExprOther. See NOTE [PmExprOther in PmExpr]

-- ----------------------------------------------------------------------------
-- | Substitution in term equalities

idSubstVarEq :: (Id -> Id) -> VarEq -> VarEq
idSubstVarEq fn (x, y) = (fn x, fn y)

idSubstSimpleEq :: (Id -> Id) -> SimpleEq -> SimpleEq
idSubstSimpleEq fn (x,e) = (fn x, idSubstPmExpr fn e)

idSubstComplexEq :: (Id -> Id) -> ComplexEq -> ComplexEq
idSubstComplexEq fn (e1,e2) = (idSubstPmExpr fn e1, idSubstPmExpr fn e2)

substComplexEq :: Id -> PmExpr -> ComplexEq -> ComplexEq
substComplexEq x e (e1, e2) = (substPmExpr x e e1, substPmExpr x e e2)

-- | Substitute in a simple equalities and partition them to the ones that
-- remain simple and the ones that become complex.
substSimpleEqs :: Id -> PmExpr -> [SimpleEq] -> ([SimpleEq], [ComplexEq])
substSimpleEqs _ _ [] = ([],[])
substSimpleEqs x e ((y,e1):rest)
  | x == y = case e of
      PmExprVar z -> ((z, e2):simple_eqs, complex_eqs)
      _other_expr -> (simple_eqs, (e, e2):complex_eqs)
  | otherwise      = ((y, e2):simple_eqs, complex_eqs)
  where (simple_eqs, complex_eqs) = substSimpleEqs x e rest
        e2 = substPmExpr x e e1

-- -----------------------------------------------------------------------
-- | Lift source expressions (HsExpr Id) to PmExpr

lhsExprToPmExpr :: LHsExpr Id -> PmExpr
lhsExprToPmExpr (L _ e) = hsExprToPmExpr e

hsExprToPmExpr :: HsExpr Id -> PmExpr

hsExprToPmExpr (HsVar         x) = PmExprVar x
hsExprToPmExpr (HsOverLit  olit) = PmExprLit (PmOLit False olit)
hsExprToPmExpr (HsLit       lit) = PmExprLit (PmSLit lit)

hsExprToPmExpr e@(NegApp _ neg_e)
  | PmExprLit (PmOLit False ol) <- hsExprToPmExpr neg_e = PmExprLit (PmOLit True ol)
  | otherwise                                           = PmExprOther e
hsExprToPmExpr (HsPar   (L _ e)) = hsExprToPmExpr e

hsExprToPmExpr e@(ExplicitTuple ps boxity)
  | all tupArgPresent ps = PmExprCon tuple_con tuple_args
  | otherwise            = PmExprOther e
  where
    tuple_con  = tupleCon (boxityNormalTupleSort boxity) (length ps)
    tuple_args = [ lhsExprToPmExpr e | L _ (Present e) <- ps ]

hsExprToPmExpr e@(ExplicitList _elem_ty mb_ol elems)
  | Nothing <- mb_ol = foldr cons nil (map lhsExprToPmExpr elems)
  | otherwise        = PmExprOther e {- overloaded list: No PmExprApp -}
  where
    cons x xs = PmExprCon consDataCon [x,xs]
    nil       = PmExprCon nilDataCon  []

hsExprToPmExpr (ExplicitPArr _elem_ty elems)
  = PmExprCon (parrFakeCon (length elems)) (map lhsExprToPmExpr elems)

-- we want this but we would have to make evrything monadic :/
-- ./compiler/deSugar/DsMonad.hs:397:dsLookupDataCon :: Name -> DsM DataCon
--
-- hsExprToPmExpr (RecordCon   c _ binds) = do
--   con  <- dsLookupDataCon (unLoc c)
--   args <- mapM lhsExprToPmExpr (hsRecFieldsArgs binds)
--   return (PmExprCon con args)
hsExprToPmExpr e@(RecordCon     _ _ _) = PmExprOther e

hsExprToPmExpr (HsTick            _ e) = lhsExprToPmExpr e
hsExprToPmExpr (HsBinTick       _ _ e) = lhsExprToPmExpr e
hsExprToPmExpr (HsTickPragma      _ e) = lhsExprToPmExpr e
hsExprToPmExpr (HsSCC             _ e) = lhsExprToPmExpr e
hsExprToPmExpr (HsCoreAnn         _ e) = lhsExprToPmExpr e
hsExprToPmExpr (ExprWithTySig   e _ _) = lhsExprToPmExpr e
hsExprToPmExpr (ExprWithTySigOut  e _) = lhsExprToPmExpr e

hsExprToPmExpr e = PmExprOther e -- the rest are not handled by the oracle

{-
%************************************************************************
%*                                                                      *
\subsection{Pretty printing}
%*                                                                      *
%************************************************************************
-}


-- f :: Int -> Bool
-- f 

-- type PmPprM a = State ([PmNegLitCt], IdSet) a


-- -----------------------------------------------------------------------------
-- | Transform residual constraints in appropriate form for pretty printing

type PmNegLitCt = (Id, (SDoc, [PmLit]))

filterComplex :: [ComplexEq] -> [PmNegLitCt]
filterComplex = zipWith rename nameList . map mkGroup
              . groupBy name . sortBy order . mapMaybe isNegLitCs
  where
    order x y = compare (fst x) (fst y)
    name  x y = fst x == fst y
    mkGroup l = (fst (head l), nub $ map snd l)
    rename new (old, lits) = (old, (new, lits))

    isNegLitCs (e1,e2)
      | isFalsePmExpr e1, Just (x,y) <- isPmExprEq e2 = isNegLitCs' x y
      | isFalsePmExpr e2, Just (x,y) <- isPmExprEq e1 = isNegLitCs' x y
      | otherwise = Nothing

    isNegLitCs' (PmExprVar x) (PmExprLit l) = Just (x, l)
    isNegLitCs' (PmExprLit l) (PmExprVar x) = Just (x, l)
    isNegLitCs' _ _             = Nothing

    nameList :: [SDoc]
    nameList = [ ptext (sLit ('t':show u)) | u <- [(0 :: Int)..] ]

-- ----------------------------------------------------------------------------

runPmPprM :: PmPprM a -> [PmNegLitCt] -> (a, [(SDoc,[PmLit])])
runPmPprM m lit_env = (result, mapMaybe is_used lit_env)
  where
    (result, (_lit_env, used)) = runState m (lit_env, emptyVarSet)

    is_used (x,(name, lits))
      | elemVarSet x used = Just (name, lits)
      | otherwise         = Nothing

type PmPprM a = State ([PmNegLitCt], IdSet) a

addUsed :: Id -> PmPprM ()
addUsed x = modify (\(negated, used) -> (negated, extendVarSet used x))

checkNegation :: Id -> PmPprM (Maybe SDoc) -- the the clean name if it is negated
checkNegation x = do
  negated <- gets fst
  return $ case lookup x negated of
    Just (new, _) -> Just new
    Nothing       -> Nothing

-- | Pretty print a pmexpr, but remember to prettify the names of the variables
-- that refer to neg-literals. The ones that cannot be shown are printed as
-- underscores.
pprPmExpr :: PmExpr -> PmPprM SDoc -- the first part of the state is read only. make it a reader? :/
pprPmExpr (PmExprVar x) = do
  mb_name <- checkNegation x
  case mb_name of
    Just name -> addUsed x >> return name
    Nothing   -> return $ if debugIsOn then ppr x
                                       else underscore
pprPmExpr (PmExprCon con args) = pprPmExprCon con args
pprPmExpr (PmExprLit l) = return (ppr l)
pprPmExpr (PmExprEq e1 e2)
  | debugIsOn = do
      e1' <- pprPmExpr e1
      e2' <- pprPmExpr e2
      return $ braces (e1' <+> equals <+> e2')
  | otherwise = return underscore
pprPmExpr (PmExprOther e)
  | debugIsOn = return (ppr e)
  | otherwise = return underscore

needsParens :: PmExpr -> Bool
needsParens (PmExprVar   {}) = False
needsParens (PmExprLit    l) = isNegatedPmLit l
needsParens (PmExprEq    {}) = False -- will become a wildcard
needsParens (PmExprOther {}) = False -- will become a wildcard
needsParens (PmExprCon c es)
  | isTupleDataCon c || isPArrFakeCon c
  || isConsDataCon c || null es = False
  | otherwise                   = True

pprPmExprWithParens :: PmExpr -> PmPprM SDoc
pprPmExprWithParens expr
  | needsParens expr = parens <$> pprPmExpr expr
  | otherwise        =            pprPmExpr expr

pprPmExprCon :: DataCon -> [PmExpr] -> PmPprM SDoc
pprPmExprCon con args
  | isTupleDataCon con = mkTuple <$> mapM pprPmExpr args
  |  isPArrFakeCon con = mkPArr  <$> mapM pprPmExpr args
  |  isConsDataCon con = pretty_list
  | dataConIsInfix con = case args of
      [x, y] -> do x' <- pprPmExprWithParens x
                   y' <- pprPmExprWithParens y
                   return (x' <+> ppr con <+> y')
      -- can it be infix but have more than two arguments?
      list   -> pprPanic "pprPmExprCon:" (ppr list)
  | null args = return (ppr con)
  | otherwise = do args' <- mapM pprPmExprWithParens args
                   return (fsep (ppr con : args'))
  where
    mkTuple, mkPArr :: [SDoc] -> SDoc
    mkTuple = parens     . fsep . punctuate comma
    mkPArr  = paBrackets . fsep . punctuate comma

    -- lazily, to be used in the list case only
    pretty_list :: PmPprM SDoc
    pretty_list = case isNilPmExpr (last elements) of
      True  -> brackets . fsep . punctuate comma <$> mapM pprPmExpr (init elements)
      False -> parens   . hcat . punctuate colon <$> mapM pprPmExpr elements

    elements = list_elements args

    list_elements [x,y]
      | PmExprCon c es <- y,  nilDataCon == c = ASSERT (null es) [x,y]
      | PmExprCon c es <- y, consDataCon == c = x : list_elements es
      | otherwise = [x,y]
    list_elements list  = pprPanic "list_elements:" (ppr list)

instance Outputable PmLit where
  ppr (PmSLit     l) = pmPprHsLit l
  ppr (PmOLit neg l) = (if neg then char '-' else empty) <> ppr l

-- not really useful for pmexprs per se
instance Outputable PmExpr where
  ppr e = fst $ runPmPprM (pprPmExpr e) []

