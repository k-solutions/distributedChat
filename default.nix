{nixpkgs ? import <nixpkgs> { }, ghc ? nixpkgs.ghc}:

with nixpkgs;

haskell.lib.buildStackProject {
  inherit ghc;
  name = "distChat";
  src = ./.;
}

