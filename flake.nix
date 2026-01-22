{
  description = "vp-ate";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?rev=9ef261221d1e72399f2036786498d78c38185c46";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        shellHook = ''
          export PATH="$HOME/.cargo/bin:$PATH"            
        '';
        buildInputs = with pkgs; [
          lldb
          libxkbcommon
          ffmpeg
          verilator
          zlib
          (python3.withPackages (p: with p; [
            cocotb
            pytest
          ]))
          gtkwave
          gnumake
        ];
      };
    };
}
