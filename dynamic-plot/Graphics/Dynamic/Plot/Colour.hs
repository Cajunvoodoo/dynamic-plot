-- |
-- Module      : Graphics.Dynamic.Plot.Colour 
-- Copyright   : (c) Justus Sagemüller 2013
-- License     : GPL v3
-- 
-- Maintainer  : (@) jsag $ hvl.no
-- Stability   : experimental
-- Portability : requires GHC>6 extensions

{-# LANGUAGE FlexibleInstances #-}

module Graphics.Dynamic.Plot.Colour ( module Graphics.Dynamic.Plot.Colour
                                    , Colour, AColour, FColour, PColour, ColourScheme
                                    ) where


import qualified Data.Colour as DCol
import Data.Colour (opaque)
import qualified Data.Colour.Names as N
import Data.Colour.CIE hiding (Colour)
import qualified Data.Colour.CIE.Illuminant as Illum

import Graphics.Dynamic.Plot.Internal.Types



neutral, contrast, grey
 , magenta, red, orange, yellow, green, cyan, blue, violet :: Colour
neutral = BaseColour Neutral
contrast= Contrast Neutral
grey    = paler contrast
magenta = Contrast Green
red     = BaseColour Red
orange  = Contrast Blue
yellow  = BaseColour Yellow
green   = BaseColour Green
cyan    = Contrast Red
blue    = BaseColour Blue
violet  = Contrast Yellow

paler, opposite :: Colour -> Colour
paler = Paler
opposite (BaseColour c) = Contrast c
opposite (Contrast c) = BaseColour c
opposite (Paler c) = Paler $ opposite c
opposite (CustomColour c) = CustomColour $ hueInvert c


defaultColourScheme :: ColourScheme
defaultColourScheme (BaseColour Neutral) = opaque N.black
defaultColourScheme (BaseColour Red    ) = opaque N.red
defaultColourScheme (BaseColour Yellow ) = opaque N.yellow
defaultColourScheme (BaseColour Green  ) = opaque N.green
defaultColourScheme (BaseColour Blue   ) = opaque N.blue
defaultColourScheme (Contrast   Neutral) = opaque N.white
defaultColourScheme (Contrast   Red    ) = opaque N.cyan
defaultColourScheme (Contrast   Yellow ) = opaque N.violet
defaultColourScheme (Contrast   Green  ) = opaque N.magenta
defaultColourScheme (Contrast   Blue   ) = opaque N.orange
defaultColourScheme (Paler c) = DCol.dissolve 0.5 $ defaultColourScheme c
defaultColourScheme (CustomColour c) = opaque c


defaultColourSeq :: [Colour] 
defaultColourSeq = cycle [blue, red, green, orange, cyan, magenta, yellow, violet]



hueInvert :: FColour -> FColour
hueInvert c = let (l,a,b) = cieLABView i c
              in cieLAB i l (1-a) (1-b)
 where i = Illum.a




class HasColour c where
  asAColourWith :: ColourScheme -> c -> AColour

instance HasColour AColour where asAColourWith _ = id
instance HasColour FColour where asAColourWith _ = DCol.opaque
instance HasColour Colour where asAColourWith = ($)
instance HasColour PColour where
  asAColourWith sch (TrueColour c) = asAColourWith sch c
  asAColourWith sch (SymbolicColour c) = asAColourWith sch c

instance (HasColour a) => HasColour (Maybe a) where
  asAColourWith sch Nothing = sch $ paler contrast
  asAColourWith sch (Just c) = asAColourWith sch c
