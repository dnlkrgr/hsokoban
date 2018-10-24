{-# LANGUAGE OverloadedStrings, RecordWildCards #-}
module Main where

import SDL
import SDL.Image
import SDL.Input.Keyboard
import SDL.Vect (Point(..))
import Linear (V4(..))
import Foreign.C.Types (CInt(..))
import qualified Paths_planetcutetest as Paths
import System.FilePath
import System.Exit
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import LevelReader (readLevels, Level(..), Coord2D(..), Element(..))
import Data.Foldable (foldl', traverse_)
import Data.List (sort)

data Block = Selector | Stone | Grass | Water | Princess | Rock | Star deriving (Eq, Ord, Show)
data Coord = Coord { x :: CInt
                   , y :: CInt
                   , z :: CInt
                   } deriving (Eq, Show, Ord)
                    
data World = World { width :: CInt
                   , depth :: CInt
                   , height :: CInt
                   , content :: Map Coord [Block]
                   } deriving (Eq, Show, Ord)

drawWorld :: Renderer -> (Block -> Texture) -> World -> IO ()
drawWorld renderer texture world =
  let
    heightInPixel = (height world - 1) * 80 + (depth world - 1) * 160
  in sequence_ $ do
      layer  <- [0..(height world)-1]
      column <- [0..(width world)-1]
      row    <- reverse [0..(depth world)-1]
      case Map.lookup (Coord column row layer) (content world) of
        Nothing    -> return $ return ()
        Just xs -> return $ traverse_ (\bt -> copy renderer (texture bt) Nothing (Just (Rectangle (P (V2 (200*column) (heightInPixel - layer * 80 - row * 160))) (V2 214 354)))) xs

setRendererSize :: Renderer -> World -> IO ()
setRendererSize renderer (World w d h _) = rendererLogicalSize renderer $= Just (V2 (w*214) (354+(d-1)*160+(h-1)*80))

appLoop :: a -> (Event -> a -> IO a) -> IO ()
appLoop gs fun = do
  event <- waitEvent
  newGS <- case eventPayload event of
        KeyboardEvent (KeyboardEventData _ Pressed _ (Keysym _ KeycodeQ _))
          -> exitSuccess
        _ -> fun event gs
  appLoop newGS fun

levelElement2Block :: Element -> Block
levelElement2Block Wall = Stone
levelElement2Block Box = Rock
levelElement2Block Player = Princess
levelElement2Block GoalSquare = Selector

addToCoord :: Map Coord [Block] -> (Coord, Block) -> Map Coord [Block]
addToCoord m (c, b) = Map.alter doIt c m
  where doIt Nothing = Just [b]
        doIt (Just xs) = Just (sort $ b : xs)

removeFromCoord :: Map Coord [Block] -> (Coord, Block) -> Map Coord [Block]
removeFromCoord m (c, b) = Map.alter doIt c m
  where doIt Nothing   = Nothing
        doIt (Just xs) = Just $ filter (/= b) xs

level2World :: Level -> World
level2World (Level xs) = World {
  width = levelWidth,
  depth = levelDepth,
  height = 2,
  content = foldl' addToCoord Map.empty $ [(Coord x y 0, Grass) | x <- [ 0 .. levelWidth - 1 ], y <- [ 0 .. levelDepth - 1 ]] ++ levelContent }
  where
  levelWidth = fromIntegral $ maximum [ x | (Coord2D x _, _) <- xs ] + 1
  levelDepth = fromIntegral $ maximum [ y | (Coord2D _ y, _) <- xs ] + 1
  levelContent = [ (Coord (fromIntegral x) (fromIntegral y) 1, levelElement2Block e) | (Coord2D x y, e) <- xs ]

data GameState = GameState {
    levelSet :: [Level]
  , actualLevel :: Int
  , world :: World
  } deriving (Eq, Ord, Show)

getPrincessPos :: Map Coord [Block] -> Coord
getPrincessPos = fst . head . filter (\(_,s) -> Princess `elem` s) . Map.toList

coordFree :: Map Coord [Block] -> Coord -> Bool
coordFree m c = case Map.lookup c m of
  Nothing -> True
  Just [] -> True
  Just [Selector] -> True
  _ -> False

coordBox :: Map Coord [Block] -> Coord -> Bool
coordBox m c = maybe False id $ (Rock `elem`) <$> Map.lookup c m 

keypressEvent :: Keycode -> (GameState -> GameState) -> Event -> GameState -> GameState
keypressEvent kc fun = \event gs -> case eventPayload event of
  (KeyboardEvent (KeyboardEventData _ Pressed _ (Keysym _ kc2 _)))
       | kc2 == kc -> fun gs
       | otherwise -> gs
  _ -> gs

nextLevel :: Event -> GameState -> GameState
nextLevel = keypressEvent KeycodeN $ \gs@GameState{..} ->
  if actualLevel + 1 < length levelSet then
    GameState { levelSet = levelSet
              , actualLevel = actualLevel + 1
              , world = level2World $ levelSet !! (actualLevel + 1)
              }
              else gs

prevLevel :: Event -> GameState -> GameState
prevLevel = keypressEvent KeycodeP $ \gs@GameState{..} ->
  if actualLevel - 1 >= 0 then
    GameState { levelSet = levelSet
              , actualLevel = actualLevel - 1
              , world = level2World $ levelSet !! (actualLevel - 1)
              }
              else gs

reloadLevel :: Event -> GameState -> GameState
reloadLevel = keypressEvent KeycodeR $ \gs@GameState{..} ->
    GameState { levelSet = levelSet
              , actualLevel = actualLevel
              , world = level2World $ levelSet !! actualLevel
              }

data Direction = Up | Down | Left | Right deriving (Eq, Show, Ord)

nextInDirection :: Direction -> Coord -> Coord
nextInDirection Up         (Coord x y z) = Coord x     (y+1) z
nextInDirection Down       (Coord x y z) = Coord x     (y-1) z
nextInDirection Main.Left  (Coord x y z) = Coord (x-1) y     z
nextInDirection Main.Right (Coord x y z) = Coord (x+1) y     z

movePlayer :: Direction -> GameState -> GameState
movePlayer d gs@GameState{..} = gs { world = world { content = doIt } }
 where m     = content world
       pPos  = getPrincessPos m
       nPos  = nextInDirection d pPos
       nnPos = nextInDirection d nPos

       movePart :: Block -> Coord -> Coord -> Map Coord [Block] -> Map Coord [Block]
       movePart b from to m = addToCoord (removeFromCoord m (from, b)) (to, b)

       movePrincess :: Map Coord [Block] -> Map Coord [Block]
       movePrincess = movePart Princess pPos nPos

       moveBox :: Map Coord [Block] -> Map Coord [Block]
       moveBox = movePart Rock nPos nnPos

       doIt :: Map Coord [Block]
       doIt = case (coordFree m nPos, coordBox m nPos, coordFree m nnPos) of
                     (True, _, _) -> movePrincess m
                     (False, True, True) -> moveBox . movePrincess $ m 
                     _ -> m


up, down, left, right :: Event -> GameState -> GameState
up = keypressEvent KeycodeUp (movePlayer Up)
down = keypressEvent KeycodeDown (movePlayer Down)
left = keypressEvent KeycodeLeft (movePlayer Main.Left)
right = keypressEvent KeycodeRight (movePlayer Main.Right)

main :: IO ()
main = do
  initializeAll
  window <- createWindow "planetcutetest" defaultWindow
  renderer <- createRenderer window (-1) defaultRenderer
  levels <- readLevels "levels.txt"
  datapath <- Paths.getDataDir
  stonetexture <- loadTexture renderer (datapath </> "images" </> "stoneblock.png")
  grasstexture <- loadTexture renderer (datapath </> "images" </> "grassblock.png")
  watertexture <- loadTexture renderer (datapath </> "images" </> "waterblock.png")
  rocktexture <-  loadTexture renderer (datapath </> "images" </> "rock.png")
  selectortexture <-  loadTexture renderer (datapath </> "images" </> "selector.png")
  startexture <-  loadTexture renderer (datapath </> "images" </> "yellow-star.png")
  princess <- loadTexture renderer (datapath </> "images" </> "Princess.png")

  let startGameState = GameState { levelSet = levels 
                                 , actualLevel = 0
                                 , world = level2World $ levels !! 0
                                 }
  appLoop startGameState $ \event gs' -> do
    let gs = foldl' (flip ($)) gs' (map ($ event)
                                   [ nextLevel
                                   , prevLevel
                                   , reloadLevel
                                   , up
                                   , down
                                   , right
                                   , left
                                   ]) -- way to clever and ugly
    setRendererSize renderer (world gs)
    clear renderer
    drawWorld renderer (\x -> case x of
                                Stone -> stonetexture
                                Water -> watertexture
                                Grass -> grasstexture
                                Princess -> princess
                                Rock -> rocktexture
                                Star -> startexture
                                Selector -> selectortexture)

              (world gs)
    present renderer
    return gs
