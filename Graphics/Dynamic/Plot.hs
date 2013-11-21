{-# LANGUAGE ScopedTypeVariables     #-}
{-# LANGUAGE RecordWildCards         #-}
{-# LANGUAGE TupleSections           #-}

module Graphics.Dynamic.Plot where


import Graphics.DrawingCombinators ((%%), R, R2)
import qualified Graphics.DrawingCombinators as Draw
import qualified Graphics.UI.GLFW as GLFW
import qualified Graphics.Rendering.OpenGL as OpenGL
import Graphics.Rendering.OpenGL (($=))

import Control.Monad
import Control.Applicative
import Control.Category
import Control.Arrow

import Prelude hiding((.), id)

import Data.List (intercalate, isPrefixOf, isInfixOf, find)
import Data.Maybe
import Data.Monoid
import Data.Foldable (foldMap)
import Data.Function (on)
import qualified Data.Map.Lazy as Map

import Data.IORef

import System.IO
import System.Exit
import Data.Time




data GraphWindowSpec = GraphWindowSpec {
      lBound, rBound, bBound, tBound :: R
    , xResolution, yResolution :: Int
  } deriving (Show)

moveStepRel :: (R, R)  -- ^ Relative translation @(Δx/w, Δy/h)@.
            -> (R, R)  -- ^ Relative zoom.
            -> GraphWindowSpec -> GraphWindowSpec
moveStepRel (δx,δy) (ζx,ζy) (GraphWindowSpec l r b t xRes yRes)
  = GraphWindowSpec l' r' b' t' xRes yRes
 where qx = (r-l)/2                  ; qy = (t-b)/2
       mx'= l + qx*(1+δx)            ; my'= b + qy*(1+δy) 
       qx'= zoomSafeGuard mx' $ qx/ζx; qy'= zoomSafeGuard my' $ qy/ζy
       l' = mx' - qx'                ; b' = my' - qy'
       r' = mx' + qx'                ; t' = my' + qy'
       zoomSafeGuard m = max (1e-250 + abs m*1e-6) . min 1e+250

type Interval = (R, R)

unionClosure :: Interval -> Interval -> Interval
unionClosure (l₁, u₁) (l₂, u₂) = (min l₁ l₂, max u₁ u₂)

data Plot = Plot {
       getPlot :: Draw.Image Any
     , plotAnnotations :: [Annotation]
  }

data DynamicPlottable = DynamicPlottable { 
        relevantRange_x :: Maybe Interval
      , relevantRange_y :: Interval -> Maybe Interval
      , usesNormalisedCanvas :: Bool
      , isTintableMonochromic :: Bool
      , axesNecessity :: Double
      , dynamicPlot :: GraphWindowSpec -> Plot
  }


initScreen :: IO ()
initScreen = do
    True <- GLFW.initialize
    True <- GLFW.openWindow (OpenGL.Size defResX defResY) [] GLFW.Window
    GLFW.windowTitle $= "Plot"
    GLFW.swapInterval $= 1
    return ()
                

plotWindow :: [DynamicPlottable] -> IO GraphWindowSpec
plotWindow graphs' = do
   let graphs = graphs' <> [dynamicAxes]
   
   initScreen
   
   viewTgt   <- newIORef $ autoDefaultView graphs
   viewState <- newIORef =<< readIORef viewTgt
   
   t₀ <- getCurrentTime
   lastFrameTime <- newIORef t₀
   
   let minKeyImpact = 0.05
   
   keyImpactState <- newIORef $ Map.fromList [ (ka, (t₀, minKeyImpact)) | ka<-[MoveLeft .. ZoomOut_y] ]
   
   done      <- newIORef False
   
   let grey = Draw.Color 0.5 0.5 0.5 0.5
       refreshScreen = do
           currentView@(GraphWindowSpec{..}) <- readIORef viewState
           let normaliseView = (Draw.scale xUnZ yUnZ <> Draw.translate (-x₀,-y₀) %%)
                  where xUnZ = 1/w; yUnZ = 1/h
                        w = (rBound - lBound)/2; h = (tBound - bBound)/2
                        x₀ = lBound + w; y₀ = bBound + h
               renderComp (DynamicPlottable{..})
                  = (if usesNormalisedCanvas then id
                      else normaliseView ) . 
                    (if False && isTintableMonochromic then Draw.tint grey 
                      else id ) $ completePlot 
                 where completePlot = getPlot $ dynamicPlot currentView
           render . mconcat $ map renderComp graphs
           GLFW.swapBuffers
           
   let mainLoop = do
           t <- getCurrentTime
           δt <- fmap (diffUTCTime t) $ readIORef lastFrameTime
           writeIORef lastFrameTime t
   
           do  -- Update / evolve view state
                   vt <- readIORef viewTgt
                   modifyIORef viewState $ \vo 
                        -> let a%b = let η = min 1 $ 2 * realToFrac δt in η*a + (1-η)*b
                           in GraphWindowSpec (lBound vt % lBound vo) (rBound vt % rBound vo)
                                              (bBound vt % bBound vo) (tBound vt % tBound vo)
                                              (xResolution vt) (yResolution vt)
           refreshScreen
           GLFW.sleep 0.01
           GLFW.pollEvents
           ($mainLoop) . unless =<< readIORef done
   
   let keyImpact key = do
           t <- getCurrentTime
           Just (_, impact) <- fmap (Map.lookup key) $ readIORef keyImpactState
           modifyIORef keyImpactState $ Map.adjust ( \(t₁, p)
                       -> (t, min 1 $ ( (p - minKeyImpact) * (exp . (*3) . realToFrac $ diffUTCTime t₁ t)
                                       + minKeyImpact ) * 2 )
                   ) key
           return impact
   
   GLFW.keyCallback $= \key state -> do
           let keyStepSize = 0.1
           when (state==GLFW.Press) $ do
              case defaultKeyMap key of
                Just QuitProgram -> writeIORef done True
                Just movement    -> do
                   impact <- keyImpact movement
                   modifyIORef viewTgt $ case movement of
                    MoveUp    -> moveStepRel (0,  impact) (1, 1)
                    MoveDown  -> moveStepRel (0, -impact) (1, 1)
                    MoveLeft  -> moveStepRel (-impact, 0) (1, 1)
                    MoveRight -> moveStepRel (impact , 0) (1, 1)
                    ZoomIn_x  -> moveStepRel (0, 0)   (1+impact, 1)
                    ZoomOut_x -> moveStepRel (0, 0)   (1-impact/2, 1)
                    ZoomIn_y  -> moveStepRel (0, 0)   (1, 1+impact/2)
                    ZoomOut_y -> moveStepRel (0, 0)   (1, 1-impact/2)
                _ -> return ()
           
   GLFW.windowSizeCallback $= \s@(OpenGL.Size xRes yRes) -> do
           OpenGL.viewport $= (OpenGL.Position 0 0, s)
           modifyIORef viewTgt $ \view -> view{ xResolution = fromIntegral xRes
                                              , yResolution = fromIntegral yRes }
           -- refreshScreen
           
   GLFW.windowCloseCallback $= do
           writeIORef done True
           return True
                 
   
   -- putStrLn "Enter Main loop..."
   
   mainLoop
   
   -- putStrLn "Done."
   
   GLFW.terminate
   
   readIORef viewState


autoDefaultView :: [DynamicPlottable] -> GraphWindowSpec
autoDefaultView graphs = finalise . flip (foldr yRanged) graphs . (, Nothing) 
                         . fromMaybe (-1, 2) $ foldr xRanged Nothing graphs
 where xRanged (DynamicPlottable {..}) Nothing = relevantRange_x
       xRanged (DynamicPlottable {..}) (Just oldrng) = fmap (unionClosure oldrng) relevantRange_x
       yRanged (DynamicPlottable {..}) (xrng, Nothing) = (xrng, relevantRange_y xrng)
       yRanged (DynamicPlottable {..}) (xrng, Just oldrng) = (xrng, fmap (unionClosure oldrng) $ relevantRange_y xrng)
       finalise ((l,r), Nothing) = addMargin $ GraphWindowSpec l r (-1) 1 defResX defResY
       finalise ((l,r), Just (b,t)) = addMargin $ GraphWindowSpec l r b t defResX defResY
       addMargin (GraphWindowSpec{..}) = GraphWindowSpec l' r' b' t' xResolution yResolution
        where w = rBound - lBound; h = tBound - bBound
              l' = lBound - w/5  ; b' = bBound - h/6
              r' = rBound + w/5  ; t' = tBound + h/6


render :: Monoid a => Draw.Image a -> IO()
render = Draw.clearRender

defResX, defResY :: Integral i => i
defResX = 640
defResY = 480


data KeyAction = MoveLeft
               | MoveRight
               | MoveUp
               | MoveDown
               | ZoomIn_x
               | ZoomOut_x
               | ZoomIn_y
               | ZoomOut_y
               | QuitProgram
   deriving (Eq, Ord, Enum)

defaultKeyMap :: GLFW.Key -> Maybe KeyAction
defaultKeyMap (GLFW.SpecialKey GLFW.UP   ) = Just MoveUp
defaultKeyMap (GLFW.SpecialKey GLFW.DOWN ) = Just MoveDown
defaultKeyMap (GLFW.SpecialKey GLFW.LEFT ) = Just MoveLeft
defaultKeyMap (GLFW.SpecialKey GLFW.RIGHT) = Just MoveRight
defaultKeyMap (GLFW.CharKey 'K') = Just MoveUp
defaultKeyMap (GLFW.CharKey 'J') = Just MoveDown
defaultKeyMap (GLFW.CharKey 'H') = Just MoveLeft
defaultKeyMap (GLFW.CharKey 'L') = Just MoveRight
defaultKeyMap (GLFW.CharKey 'B') = Just ZoomIn_x
defaultKeyMap (GLFW.CharKey 'N') = Just ZoomOut_x
defaultKeyMap (GLFW.CharKey 'I') = Just ZoomIn_y
defaultKeyMap (GLFW.CharKey 'O') = Just ZoomOut_y
defaultKeyMap (GLFW.SpecialKey GLFW.ESC) = Just QuitProgram
defaultKeyMap _ = Nothing




fnPlot :: (R -> R) -> DynamicPlottable
fnPlot f = DynamicPlottable{
               relevantRange_x = Nothing
             , relevantRange_y = yRangef
             , usesNormalisedCanvas = False
             , isTintableMonochromic = True
             , axesNecessity = 1
             , dynamicPlot = plot }
 where yRangef (l, r) = Just . (minimum &&& maximum) $ map f [l, l + (r-l)/8 .. r]
       plot (GraphWindowSpec{..}) = Plot curve []
        where δx = (rBound - lBound) * 2 / fromIntegral xResolution
              curve = trace [ (x, f x) | x<-[lBound, lBound+δx .. rBound] ]
              trace (p:q:ps) = Draw.line p q <> trace (q:ps)
              trace _ = mempty




data AxesStyle = DynamicAxesStyle
data DynamicAxes = DynamicAxes { yAxisClasses, xAxisClasses :: [AxisClass] }
data AxisClass = AxisClass { visibleAxes :: [Axis], axisStrength :: Double }
data Axis = Axis { axisPosition :: R } --, decPrecision :: Int }

crtDynamicAxes :: GraphWindowSpec -> DynamicAxes
crtDynamicAxes (GraphWindowSpec {..}) = DynamicAxes yAxCls xAxCls
 where [yAxCls, xAxCls] = zipWith3 directional 
                        [lBound, bBound] [rBound, tBound] [xResolution, yResolution]
       directional l u res = map lvl lvlSpecs -- takeWhile ((>0.1) . axisStrength) . scanl purgeDups [] $ aCls
        where -- aCls =  
              span = u - l
              upDecaSpan = 10**(ceil $ lg span)
              pixelScale = span / (fromIntegral res * upDecaSpan)
              baseDecaval = upDecaSpan * (flor $ l / upDecaSpan)
              lvl (minSpc, strength) 
                = AxisClass [Axis v  | i<-[0 .. luDSdiv*2], let v=(baseDecaval + i*laSpc), v<u ] 
                            strength
               where laSpc = upDecaSpan / luDSdiv
                     luDSdiv = last . takeWhile (\d -> pixelScale * minSpc < 1/d )
                                      . join $ iterate (map(*10)) [1, 2, 5]
              ceil = fromIntegral . ceiling
              flor = fromIntegral . floor
       lvlSpecs = [ (80, 0.3), (18, 0.1) ]



dynamicAxes :: DynamicPlottable
dynamicAxes = DynamicPlottable { 
               relevantRange_x = Nothing
             , relevantRange_y = const Nothing
             , usesNormalisedCanvas = False
             , isTintableMonochromic = True
             , axesNecessity = -1
             , dynamicPlot = plot }
 where plot gwSpec@(GraphWindowSpec{..}) = Plot lines labels
        where (DynamicAxes yAxCls xAxCls) = crtDynamicAxes gwSpec
              lines = Draw.line (lBound, 0) (rBound, 0)  `provided`(bBound < 0 && tBound > 0)
                   <> Draw.line (0, bBound) (0, tBound)  `provided`(lBound < 0 && rBound > 0)
                   <> foldMap (renderClass $ \x -> ((x, bBound), ((x, tBound)))) yAxCls
                   <> foldMap (renderClass $ \y -> ((lBound, y), ((rBound, y)))) xAxCls
              labels = do (dirq, acl) <- zip [\x->(x,0), \y->(0,y)] [yAxCls, xAxCls]
                          let prepAnnotation (Axis{axisPosition=z}) 
                                              = Annotation (TextAnnotation txt align) place False
                               where txt = PlainText $ show z
                                     place = ExactPlace $ dirq z
                                     align = TextAlignment AlignMid AlignMid
                          map prepAnnotation . visibleAxes $ head acl
       renderClass crd (AxisClass axes strength)
          = Draw.tint (let s = realToFrac strength in Draw.Color s s s 1)
              $ foldMap (uncurry Draw.line . crd . axisPosition) axes
 


data Annotation = Annotation {
         getAnnotation :: AnnotationObj 
       , placement     :: AnnotationPlace
       , isOptional    :: Bool
   }
data AnnotationObj = TextAnnotation TextObj TextAlignment
data AnnotationPlace = ExactPlace R2

data TextObj = PlainText String
data TextAlignment = TextAlignment { hAlign, vAlign :: Alignment } -- , blockSpread :: Bool }
data Alignment = AlignBottom | AlignMid | AlignTop

data DiagramTK = DiagramTK { textTools :: TextTK }
data TextTK = TextTK { defaultFont :: Draw.Font
                     , txtSize, padding, extraTopPad :: R }

prerenderAnnotation :: DiagramTK -> Annotation -> Draw.Image Any
prerenderAnnotation (DiagramTK{ textTools = TextTK{..} }) (Annotation{..})
       | TextAnnotation (PlainText str) (TextAlignment{..}) <- getAnnotation
       , ExactPlace p <- placement
            = let (rnTextLines, lineWidths) 
                       = unzip . map (Draw.text defaultFont &&& Draw.textWidth defaultFont) 
                            $ lines str
                  nLines = length lineWidths
                  lineHeight = 1 + extraTopPad + 2*padding
                  ζ = txtSize / lineHeight
                  width' = maximum $ 0 : lineWidths
                  width  = width + 2*padding
                  height = fromIntegral nLines * lineHeight
                  y₀ = case vAlign of
                              AlignBottom -> height
                              AlignMid    -> height/2
                              AlignTop    -> 0
                  fullText = mconcat $ zipWith3 ( \n w -> 
                                 let y = n*lineHeight
                                 in (Draw.translate (case hAlign of 
                                      AlignBottom -> (0             , y₀-y)
                                      AlignMid    -> ((width' - w)/2, y₀-y)
                                      AlignTop    -> (width' - w    , y₀-y)
                                     ) %% ) ) [0..] lineWidths rnTextLines
              in Draw.translate p <> Draw.scale ζ ζ %% fullText
        


infixl 7 `provided`
provided :: Monoid m => m -> Bool -> m
provided m True = m
provided m False = mempty


lg :: Floating a => a -> a
lg x = log x / log 10


