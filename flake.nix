{
  description = "vp-ate";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
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
          iverilog
          zlib
          (python312.withPackages (p: with p; [
            cocotb
            pytest
          ]))
          sv-lang
          verible
          gtkwave
          gnumake
        ];
      };
    };
}
