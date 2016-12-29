module TranslateCore(
  Reference,
  SyntaxGraph(..),
  EvalContext,
  GraphAndRef(..),
  SgSink(..),
  SgBind(..),
  syntaxGraphFromNodes,
  syntaxGraphFromNodesEdges,
  bindsToSyntaxGraph,
  graphAndRefToGraph,
  getUniqueName,
  getUniqueString,
  edgesForRefPortList,
  combineExpressions,
  --qualifyNameAndPort,
  makeApplyGraph,
  namesInPattern,
  lookupReference,
  deleteBindings,
  makeEdges,
  --makeEdgesCore,
  makeBox,
  nTupleString,
  nListString,
  syntaxGraphToFglGraph,
  nodeToIcon,
  initialIdState
) where

import Control.Monad.State(State, state)
import Data.Either(partitionEithers)
import qualified Data.Graph.Inductive.PatriciaTree as FGR
import qualified Data.Graph.Inductive.Graph as ING
import Data.List(find)
import Data.Semigroup(Semigroup, (<>))

import Types(Icon, SyntaxNode(..), Edge(..), EdgeOption(..),
  NameAndPort(..), IDState, SgNamedNode(..), NodeName(..), Port(..),
  LikeApplyFlavor(..), CaseOrGuardTag(..), IDState(..))
import Util(noEnds, nameAndPort, makeSimpleEdge, justName, maybeBoolToBool, mapNodeInNamedNode, nodeNameToInt)
import Icons(Icon(..))

-- OVERVIEW --
-- This module has the core functions and data types used by Translate.
-- This module also contains most/all of the translation functions that
-- do not require Language.Haskell.Exts.

type Reference = Either String NameAndPort

type EvalContext = [String]

data SgBind = SgBind String Reference deriving (Eq, Show, Ord)

data SgSink = SgSink String NameAndPort deriving (Eq, Ord, Show)

-- TODO Replace lists with sets
-- | SyntaxGraph is an abstract representation for Haskell syntax. SyntaxGraphs are
-- generated from the Haskell syntax tree, and are used to generate Drawings
data SyntaxGraph = SyntaxGraph {
  sgNodes :: [SgNamedNode],
  sgEdges :: [Edge],
  sgSinks :: [SgSink],
  sgBinds :: [SgBind],
  -- sgEmbedMap keeps track of nodes embedded in other nodes. If (child, parent) is in the Map, then child is embedded inside parent.
  sgEmbedMap :: [(NodeName, NodeName)]
  } deriving (Show, Eq)

instance Semigroup SyntaxGraph where
  (SyntaxGraph icons1 edges1 sinks1 sources1 map1) <> (SyntaxGraph icons2 edges2 sinks2 sources2 map2) =
    SyntaxGraph (icons1 <> icons2) (edges1 <> edges2) (sinks1 <> sinks2) (sources1 <> sources2) (map1 <> map2)

instance Monoid SyntaxGraph where
  mempty = SyntaxGraph mempty mempty mempty mempty mempty
  mappend = (<>)

data GraphAndRef = GraphAndRef SyntaxGraph Reference

-- BEGIN Constructors and Destructors

sgBindToString :: SgBind -> String
sgBindToString (SgBind s _) = s

sgBindToTuple :: SgBind -> (String, Reference)
sgBindToTuple (SgBind s r) = (s, r)

syntaxGraphFromNodes :: [SgNamedNode] -> SyntaxGraph
syntaxGraphFromNodes icons = SyntaxGraph icons mempty mempty mempty mempty

syntaxGraphFromNodesEdges :: [SgNamedNode] -> [Edge] -> SyntaxGraph
syntaxGraphFromNodesEdges icons edges = SyntaxGraph icons edges mempty mempty mempty

bindsToSyntaxGraph :: [SgBind] -> SyntaxGraph
bindsToSyntaxGraph binds = SyntaxGraph mempty mempty mempty binds mempty

sinksToSyntaxGraph :: [SgSink] -> SyntaxGraph
sinksToSyntaxGraph sinks = SyntaxGraph mempty mempty sinks mempty mempty

edgesToSyntaxGraph :: [Edge] -> SyntaxGraph
edgesToSyntaxGraph edges = SyntaxGraph mempty edges mempty mempty mempty

graphAndRefToGraph :: GraphAndRef -> SyntaxGraph
graphAndRefToGraph (GraphAndRef g _) = g

-- END Constructors and Destructors

-- BEGIN IDState

initialIdState :: IDState
initialIdState = IDState 0

getId :: State IDState Int
getId = state incrementer where
  incrementer (IDState x) = (x, IDState checkedIncrement) where
    xPlusOne = x + 1
    checkedIncrement = if xPlusOne > x
      then xPlusOne
      else error "getId: the ID state has overflowed."



getUniqueName :: State IDState NodeName
getUniqueName = fmap NodeName getId

getUniqueString :: String -> State IDState String
getUniqueString base = fmap ((base ++). show) getId

-- END IDState

-- TODO: Refactor with combineExpressions
edgesForRefPortList :: Bool -> [(Reference, NameAndPort)] -> SyntaxGraph
edgesForRefPortList inPattern portExpPairs = mconcat $ fmap makeGraph portExpPairs where
  edgeOpts = if inPattern then [EdgeInPattern] else []
  makeGraph (ref, port) = case ref of
    Left str -> if inPattern
      then bindsToSyntaxGraph [SgBind str (Right port)]
      else sinksToSyntaxGraph [SgSink str port]
    Right resultPort -> edgesToSyntaxGraph [Edge edgeOpts noEnds connection] where
      connection = if inPattern
        -- If in a pattern, then the port on the case icon is the data source.
        then (port, resultPort)
        else (resultPort, port)

combineExpressions :: Bool -> [(GraphAndRef, NameAndPort)] -> SyntaxGraph
combineExpressions inPattern portExpPairs = mconcat $ fmap makeGraph portExpPairs where
  edgeOpts = if inPattern then [EdgeInPattern] else []
  makeGraph (GraphAndRef graph ref, port) = graph <> case ref of
    Left str -> if inPattern
      then bindsToSyntaxGraph [SgBind str (Right port)]
      else sinksToSyntaxGraph [SgSink str port]
    Right resultPort -> edgesToSyntaxGraph [Edge edgeOpts noEnds (resultPort, port)]

-- qualifyNameAndPort :: String -> NameAndPort -> NameAndPort
-- qualifyNameAndPort s (NameAndPort n p) = NameAndPort (s DIA..> n) p

makeApplyGraph :: LikeApplyFlavor -> Bool -> NodeName -> GraphAndRef -> [GraphAndRef] -> Int -> (SyntaxGraph, NameAndPort)
makeApplyGraph applyFlavor inPattern applyIconName funVal argVals numArgs = (newGraph <> combinedGraph, nameAndPort applyIconName (Port 1))
  where
    argumentPorts = map (nameAndPort applyIconName . Port) [2,3..]
    functionPort = nameAndPort applyIconName (Port 0)
    combinedGraph = combineExpressions inPattern $ zip (funVal:argVals) (functionPort:argumentPorts)
    icons = [SgNamedNode applyIconName (LikeApplyNode applyFlavor numArgs)]
    newGraph = syntaxGraphFromNodes icons

namesInPatternHelper :: GraphAndRef -> [String]
namesInPatternHelper (GraphAndRef graph ref) = case ref of
  Left str -> [str]
  Right _ -> sgBindToString <$> sgBinds graph

namesInPattern :: (GraphAndRef, Maybe String) -> [String]
namesInPattern (graphAndRef, mName) = case mName of
  Nothing -> otherNames
  Just n -> n : otherNames
  where
    otherNames = namesInPatternHelper graphAndRef

-- | Recursivly find the matching reference in a list of bindings.
-- TODO: Might want to present some indication if there is a reference cycle.
lookupReference :: [SgBind] -> Reference -> Reference
lookupReference _ ref@(Right _) = ref
lookupReference bindings ref@(Left originalS) = lookupHelper ref where
  lookupHelper newRef@(Right _) = newRef
  lookupHelper newRef@(Left s)= case lookup s (fmap sgBindToTuple bindings) of
    Just r -> failIfCycle r $ lookupHelper r
    Nothing -> newRef
    where
      failIfCycle r@(Left newStr) res = if newStr == originalS then r else res
      failIfCycle _ res = res

deleteBindings :: SyntaxGraph -> SyntaxGraph
deleteBindings (SyntaxGraph a b c _ e) = SyntaxGraph a b c mempty e

makeEdgesCore :: [SgSink] -> [SgBind] -> ([SgSink], [Edge])
makeEdgesCore sinks bindings = partitionEithers $ fmap renameOrMakeEdge sinks
  where
    renameOrMakeEdge :: SgSink -> Either SgSink Edge
    renameOrMakeEdge orig@(SgSink s destPort) = case lookup s (fmap sgBindToTuple bindings) of
      Just ref -> case lookupReference bindings ref of
        (Right sourcePort) -> Right $ makeSimpleEdge (sourcePort, destPort)
        (Left newStr) -> Left $ SgSink newStr destPort
      Nothing -> Left orig

makeEdges :: SyntaxGraph -> SyntaxGraph
makeEdges (SyntaxGraph icons edges sinks bindings eMap) = newGraph where
  (newSinks, newEdges) = makeEdgesCore sinks bindings
  newGraph = SyntaxGraph icons (newEdges <> edges) newSinks bindings eMap

-- TODO: remove / change due toSyntaxGraph
makeBox :: String -> State IDState (SyntaxGraph, NameAndPort)
makeBox str = do
  name <- getUniqueName
  let graph = syntaxGraphFromNodes [SgNamedNode name (LiteralNode str)]
  pure (graph, justName name)

nTupleString :: Int -> String
nTupleString n = '(' : replicate (n -1) ',' ++ ")"

nListString :: Int -> String
-- TODO: Use something better than [_]
nListString 1 = "[_]"
nListString n = '[' : replicate (n -1) ',' ++ "]"

nodeToIcon :: SyntaxNode -> Icon
nodeToIcon (LikeApplyNode ApplyNodeFlavor n) = ApplyAIcon n
nodeToIcon (LikeApplyNode ComposeNodeFlavor n) = ComposeIcon n
nodeToIcon (NestedApplyNode flavor x edges) = nestedApplySyntaxNodeToIcon flavor x edges
nodeToIcon (PatternApplyNode s n) = PAppIcon n s
-- nodeToIcon (NestedPatternApplyNode s n children) = nestedPatternNodeToIcon s n children
nodeToIcon (NestedPatternApplyNode s children) = nestedPatternNodeToIcon s children
nodeToIcon (NameNode s) = TextBoxIcon s
nodeToIcon (BindNameNode s) = BindTextBoxIcon s
nodeToIcon (LiteralNode s) = TextBoxIcon s
nodeToIcon (FunctionDefNode n) = FlatLambdaIcon n
nodeToIcon (GuardNode n) = GuardIcon n
nodeToIcon (CaseNode n) = CaseIcon n
nodeToIcon CaseResultNode = CaseResultIcon
nodeToIcon (NestedCaseOrGuardNode tag x edges) = nestedCaseOrGuardNodeToIcon tag x edges

makeArg :: [(SgNamedNode, Edge)] -> Int -> Maybe (NodeName, Icon)
makeArg args port = case find (findArg (Port port)) args of
  Nothing -> Nothing
  Just (SgNamedNode argName argSyntaxNode, _) -> Just (argName, nodeToIcon argSyntaxNode)

nestedApplySyntaxNodeToIcon :: LikeApplyFlavor -> Int -> [(SgNamedNode, Edge)] -> Icon
nestedApplySyntaxNodeToIcon flavor numArgs args = NestedApply flavor argList where
  -- argList should be of length numArgs + 1, since argList includes the function expression
  -- port 0 is the function, ports 2..(numArgs+1) are the arguments
  -- TODO Don't use hardcoded port numbers
  argList = fmap (makeArg args) (0:[2..numArgs + 1])

nestedCaseOrGuardNodeToIcon :: CaseOrGuardTag -> Int -> [(SgNamedNode, Edge)] -> Icon
nestedCaseOrGuardNodeToIcon tag numArgs args = case tag of
  CaseTag -> NestedCaseIcon argList
  GuardTag -> NestedGuardIcon argList
  where
    argList = fmap (makeArg args) (0:[2..( 1 + (2 * numArgs))])

nestedPatternNodeToIcon :: String -> [Maybe SgNamedNode] -> Icon
nestedPatternNodeToIcon str children = NestedPApp $
  Just (NodeName (-1), TextBoxIcon str)
  :
  (fmap (mapNodeInNamedNode nodeToIcon) <$> children)

nestedPatternNodeToIcon' :: String -> Int -> [(SgNamedNode, Edge)] -> Icon
nestedPatternNodeToIcon' str numArgs args = NestedPApp argList where
  -- TODO Don't use NodeName (-1)
  -- TODO Don't use hardcoded port numbers
  argList = Just (NodeName (-1), TextBoxIcon str) : fmap (makeArg args) [2..numArgs + 1]

findArg :: Port -> (SgNamedNode, Edge) -> Bool
findArg currentPort (SgNamedNode argName _, Edge _ _ (NameAndPort fromName fromPort, NameAndPort toName toPort))
  | argName == fromName = maybeBoolToBool $ fmap (== currentPort) toPort
  | argName == toName = maybeBoolToBool $ fmap (== currentPort) fromPort
  | otherwise = False -- This case should never happen

makeLNode :: SgNamedNode -> ING.LNode SgNamedNode
makeLNode namedNode@(SgNamedNode (NodeName name) _) = (name, namedNode)

lookupInEmbeddingMap :: NodeName -> [(NodeName, NodeName)] -> NodeName
lookupInEmbeddingMap origName eMap = lookupHelper origName where
  lookupHelper name = case lookup name eMap of
    Nothing -> name
    Just parent -> if parent == origName
      then error $ "lookupInEmbeddingMap: Found cycle. Node = " ++ show origName ++ "\nEmbedding Map = " ++ show eMap
      else lookupHelper parent

syntaxGraphToFglGraph :: SyntaxGraph -> FGR.Gr SgNamedNode Edge
syntaxGraphToFglGraph (SyntaxGraph nodes edges _ _ eMap) =
  ING.mkGraph (fmap makeLNode nodes) labeledEdges where
    labeledEdges = fmap makeLabeledEdge edges

    makeLabeledEdge e@(Edge _ _ (NameAndPort name1 _, NameAndPort name2 _)) =
      (nodeNameToInt $ lookupInEmbeddingMap name1 eMap, nodeNameToInt $ lookupInEmbeddingMap name2 eMap, e)
