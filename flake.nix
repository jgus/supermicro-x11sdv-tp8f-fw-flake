{
  description = "Devshell + bundled firmware for flashing Supermicro X11SDV-4C-TP8F (SYS-5019D-4C-FN8TP) BIOS/BMC in-band";

  # Standalone flashing toolbox (entered via `nix develop github:jgus/supermicro-fw-flake`), self-contained with its
  # own nixpkgs pin and the proprietary firmware committed alongside. Makes no assumptions about the host it flashes —
  # intended to run from a bare machine or a NixOS live installer.
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
          # Keep SUM's vendor layout intact (sum resolves ExternalData/ and the sum_bios driver source relative to its
          # own location) and expose it on PATH via a symlink — /proc/self/exe still resolves into the libexec dir.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/libexec/supermicro-sum
            cp -r sum ExternalData driver ReleaseNote.txt SUM_UserGuide.pdf $out/libexec/supermicro-sum/ 2>/dev/null || true
            chmod +x $out/libexec/supermicro-sum/sum
            mkdir -p $out/bin
            ln -s $out/libexec/supermicro-sum/sum $out/bin/sum
            runHook postInstall
          '';
          meta = {
            description = "Supermicro Update Manager (in-band BIOS/BMC flasher)";
            license = pkgs.lib.licenses.unfree;
            platforms = [ "x86_64-linux" ];
            mainProgram = "sum";
          };
        };

        # Loads the IPMI KCS modules from the *running* kernel (the flake can't ship kernel modules — they're tied to the
        # booted kernel, not nixpkgs). `sudo` resolves modprobe from the host system, so this works on a NixOS installer.
        load-ipmi = pkgs.writeShellScriptBin "smc-load-ipmi" ''
          set -e
          echo "Loading IPMI modules from the running kernel: ipmi_si ipmi_devintf"
          sudo modprobe ipmi_si ipmi_devintf
          if [ -e /dev/ipmi0 ]; then
            echo "/dev/ipmi0 is present — in-band sum is ready."
          else
            echo "No /dev/ipmi0 after modprobe — board may lack IPMI/KCS, or the running kernel lacks the modules." >&2
            exit 1
          fi
        '';

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
            load-ipmi
            pkgs.ipmitool
            pkgs.pciutils
            pkgs.dmidecode
          ];
          shellHook = ''
            export SMC_FW="${firmware}"
            export SMC_BIOS="${bios}"
            export SMC_BMC="${bmc}"
            echo "--- Supermicro X11SDV-4C-TP8F (SYS-5019D-4C-FN8TP) firmware shell ---"
            echo "sum 2.15.0 | ipmitool | pciutils | dmidecode   BIOS 2.2 / BMC 01.74.13 in \$SMC_FW"
            echo "Confirm the board first:  sudo dmidecode -t baseboard"
            echo
            echo "In-band sum talks to the BMC over /dev/ipmi0 (IPMI KCS). On a fresh boot / live installer it isn't loaded yet:"
            if [ -e /dev/ipmi0 ]; then
              echo "  /dev/ipmi0: present"
            else
              echo "  /dev/ipmi0: MISSING -> run  smc-load-ipmi   (sudo modprobe ipmi_si ipmi_devintf, from the running kernel)"
            fi
            echo
            echo "Use tmux/screen, ensure stable power. Order: BMC first, then BIOS."
            echo "  BMC:   sudo sum -c UpdateBmc  --file \"\$SMC_BMC\""
            echo "  BIOS:  sudo sum -c UpdateBios --file \"\$SMC_BIOS\" --preserve_setting --reboot"
            echo
            echo "No-OS alternatives:  BMC -> web UI Maintenance/Firmware Update."
            echo "                     BIOS -> boot UEFI shell from USB, run flash.nsh (afuefi) from \$SMC_FW/bios."
          '';
        };
      });
}
