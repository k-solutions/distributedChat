{ nixpkgs ? import <nixpkgs> {}, compiler ? "ghc822", doBenchmark ? false }:

let

  inherit (nixpkgs) pkgs;

  f = { mkDerivation, base, binary, distributed-process
      , distributed-process-simplelocalnet, distributed-static, hpack
      , network, network-transport-tcp, stdenv, template-haskell
      }:
      mkDerivation {
        pname = "distChat";
        version = "0.1.0.0";
        src = ./.;
        isLibrary = false;
        isExecutable = true;
        libraryHaskellDepends = [
          base binary distributed-process distributed-process-simplelocalnet
          distributed-static network network-transport-tcp template-haskell
        ];
        libraryToolDepends = [ hpack ];
        executableHaskellDepends = [
          base binary distributed-process distributed-process-simplelocalnet
          distributed-static network network-transport-tcp template-haskell
        ];
        testHaskellDepends = [
          base binary distributed-process distributed-process-simplelocalnet
          distributed-static network network-transport-tcp template-haskell
        ];
        prePatch = "hpack";
        homepage = "https://github.com/k-solutions/distChat#readme";
        description = "Distributed chat from the Simon Marlow \"Parallel and Concurrent Programing in Haskell\"";
        license = stdenv.lib.licenses.bsd3;
      };

  haskellPackages = if compiler == "default"
                       then pkgs.haskellPackages
                       else pkgs.haskell.packages.${compiler};

  variant = if doBenchmark then pkgs.haskell.lib.doBenchmark else pkgs.lib.id;

  drv = variant (haskellPackages.callPackage f {});

in

  if pkgs.lib.inNixShell then drv.env else drv
