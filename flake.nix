{
  description = "Devshell + bundled firmware for flashing Supermicro X11SDV-4C-TP8F (SYS-5019D-4C-FN8TP) BIOS/BMC in-band";

  # Standalone flashing toolbox (entered via `nix develop github:jgus/supermicro-fw-flake`), not consumed by any
  # nixosConfiguration, so it carries its own nixpkgs pin. The proprietary firmware bundle is committed alongside.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # SUM and the firmware blob are proprietary Supermicro binaries.
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

        # Supermicro Update Manager — proprietary glibc ELF; in-band flasher for BOTH BIOS (UpdateBios) and BMC (UpdateBmc).
        # Direct, fetchable vendor URL (the click-through portal only gates the firmware bundle, not the SUM tarball).
        sum = pkgs.stdenv.mkDerivation {
          pname = "supermicro-sum";
          version = "2.15.0";
          src = pkgs.fetchurl {
            url = "https://www.supermicro.com/Bios/sw_download/1026/sum_2.15.0_Linux_x86_64_20251104.tar.gz";
            hash = "sha256-bRlGDrpeac/SN5eAfDgh44c5w9JiIKbEDcaiQ4k0g+I=";
          };
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            install -Dm755 sum $out/bin/sum
            # Keep the in-band BIOS driver source (sum_bios.ko) + ExternalData/docs for reference.
            mkdir -p $out/share/supermicro-sum
            cp -r driver ExternalData ReleaseNote.txt SUM_UserGuide.pdf $out/share/supermicro-sum/ 2>/dev/null || true
            runHook postInstall
          '';
          meta = {
            description = "Supermicro Update Manager (in-band BIOS/BMC flasher)";
            license = pkgs.lib.licenses.unfree;
            platforms = [ "x86_64-linux" ];
            mainProgram = "sum";
          };
        };

        # X11SDV-TP8F software package (BIOS 2.2 / 2024-09-03, BMC 01.74.13 / 2023-08-02), committed to this repo.
        # The bundle nests per-component zips; extract them so the flashable images sit at predictable paths.
        firmware = pkgs.stdenv.mkDerivation {
          pname = "x11sdv-tp8f-firmware";
          version = "2.2_AS01.74.13";
          src = ./X11SDV-TP8F_2.2_AS01.74.13_SUM2.14.0.zip;
          nativeBuildInputs = [ pkgs.unzip ];
          dontConfigure = true;
          dontBuild = true;
          unpackPhase = "unzip -q $src -d outer";
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bios $out/bmc
            unzip -q "outer/BIOS_X11SDV-0986_20240903_2.2_STDsp.zip" -d $out/bios
            unzip -q "outer/BMC_X11AST2500-4101MS_20230802_01.74.13_STDsp.zip" -d $out/bmc
            cp outer/X11SDV-TP8F_Software_Package_Readme.txt $out/ 2>/dev/null || true
            runHook postInstall
          '';
          meta = {
            description = "Supermicro X11SDV-TP8F BIOS 2.2 + BMC 01.74.13 firmware bundle";
            license = pkgs.lib.licenses.unfree;
            platforms = [ "x86_64-linux" ];
          };
        };

        bios = "${firmware}/bios/BIOS_X11SDV-0986_20240903_2.2_STDsp.bin";
        bmc = "${firmware}/bmc/BMC_X11AST2500-4101MS_20230802_01.74.13_STDsp.bin";
      in
      {
        packages = { inherit sum firmware; default = sum; };

        devShells.default = pkgs.mkShellNoCC {
          buildInputs = [
            sum
            pkgs.ipmitool
            pkgs.pciutils
          ];
          shellHook = ''
            export SMC_FW="${firmware}"
            export SMC_BIOS="${bios}"
            export SMC_BMC="${bmc}"
            echo "--- Supermicro X11SDV-4C-TP8F (SYS-5019D-4C-FN8TP) firmware shell ---"
            echo "sum 2.15.0 | ipmitool | pciutils    BIOS 2.2 / BMC 01.74.13 in \$SMC_FW"
            echo
            echo "Run in-band ON THE TARGET (needs /dev/ipmi0 — ipmi_si + ipmi_devintf are loaded by machine.hasIpmi=true)."
            echo "Use tmux/screen, ensure stable power. Recommended order: BMC first, then BIOS."
            echo
            echo "  BMC:   sudo sum -c UpdateBmc  --file \"\$SMC_BMC\""
            echo "         (or, zero tooling: BMC web UI -> Maintenance -> Firmware Update — free, no license)"
            echo "  BIOS:  sudo sum -c UpdateBios --file \"\$SMC_BIOS\" --preserve_setting --reboot"
            echo
            echo "In-band SUM BIOS/BMC needs NO license. OOB SUM and BIOS-via-web-UI need SFT-DCMS-SINGLE."
            echo "EFI-shell alternative: \$SMC_FW/bios/flash.nsh (afuefi.smc) and \$SMC_FW/bmc/2.09/AuUpdate.efi."
          '';
        };
      });
}
