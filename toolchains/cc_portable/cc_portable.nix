# This is a Nix script to create a portable C++ toolchain by patching binaries and bundling dependencies
{
  # The base toolchain info from the standard CC toolchain
  baseToolchainInfo ? "",

  # Arguments passed to patchelf for RPATH
  portableRPath ? "$ORIGIN/../lib",

  # Whether to include the dynamic linker
  includeDynamicLinker ? true,

  # Whether to statically link patchelf for bootstrapping
  staticPatchelf ? true,

  # We need nixpkgs to get the patchelf utility
  nixpkgs ? import <nixpkgs> { },
}:

let
  inherit (nixpkgs) lib;

  # Utilities
  patchelf = if staticPatchelf then nixpkgs.pkgsStatic.patchelf else nixpkgs.patchelf;

  # Get the base toolchain info from the provided file
  baseToolchainInfoContent = builtins.readFile baseToolchainInfo;

  # Parse the base toolchain info
  parseLine =
    line:
    let
      parts = lib.splitString ":" line;
      key = lib.head parts;
      values = lib.tail parts;
    in
    {
      inherit key values;
    };

  parseInfo =
    content:
    let
      lines = lib.filter (line: line != "") (lib.splitString "\n" content);
      parsed = map parseLine lines;
      toEntry = p: {
        name = p.key;
        value = p.values;
      };
    in
    builtins.listToAttrs (map toEntry parsed);

  baseInfo = parseInfo baseToolchainInfoContent;

  # Get the tool paths from the base info
  toolNames = baseInfo.TOOL_NAMES;
  toolPaths = baseInfo.TOOL_PATHS;

  # Get all paths to ELF binaries
  toolPathList = lib.zipLists toolNames toolPaths;

  # Detect platform
  isDarwin = nixpkgs.stdenv.isDarwin;
  isLinux = nixpkgs.stdenv.isLinux;

  # Function to determine if a file is an ELF binary
  isElfFile = path: lib.strings.hasPrefix "\127ELF" (builtins.readFile path);

  # Function to determine if a file is a Mach-O binary
  isMachOFile =
    path:
    let
      fileResult = builtins.readFile (
        nixpkgs.runCommand "file-check" { } ''
          ${nixpkgs.file}/bin/file -b ${path} > $out
        ''
      );
    in
    lib.strings.hasInfix "Mach-O" fileResult;

  # Function to get all shared library dependencies of an ELF binary
  getElfDeps =
    binary:
    let
      lddOutput = builtins.readFile (
        nixpkgs.runCommand "ldd-output" { } ''
          ${nixpkgs.glibc}/bin/ldd ${binary} | grep -v "not found" | awk '{print $3}' | grep -v "^$" > $out
        ''
      );
      paths = lib.filter (path: path != "") (lib.splitString "\n" lddOutput);
    in
    paths;

  # Function to get all shared library dependencies of a Mach-O binary
  getMachODeps =
    binary:
    let
      otoolOutput = builtins.readFile (
        nixpkgs.runCommand "otool-output" { } ''
          ${nixpkgs.darwin.cctools}/bin/otool -L ${binary} | tail -n +2 | awk '{print $1}' | grep -v "^$" > $out
        ''
      );
      paths = lib.filter (path: path != "") (lib.splitString "\n" otoolOutput);
      # Filter out system libraries and self-references
      filteredPaths = lib.filter (
        path:
        !(lib.strings.hasPrefix "/usr/lib" path)
        && !(lib.strings.hasPrefix "/System" path)
        && !(lib.strings.hasPrefix "@executable_path" path)
        && !(lib.strings.hasPrefix "@loader_path" path)
        && !(lib.strings.hasPrefix "@rpath" path)
      ) paths;
    in
    filteredPaths;

  # Function to find the dynamic linker in a binary
  getInterpreter =
    binary:
    let
      interpOutput = builtins.readFile (
        nixpkgs.runCommand "interpreter" { } ''
          ${patchelf}/bin/patchelf --print-interpreter ${binary} 2>/dev/null || echo "" > $out
        ''
      );
    in
    lib.strings.removePrefix "\n" (lib.strings.removeSuffix "\n" interpOutput);

  # Build the portable toolchain
  buildPortableToolchain = nixpkgs.runCommand "portable-cc-toolchain" { } ''
    # Create directory structure
    mkdir -p $out/bin $out/lib $out/libexec $out/include

    # Copy the toolchain binaries
    ${lib.concatMapStringsSep "\n" (entry: ''
      # Copying ${lib.elemAt entry 0} (${lib.elemAt entry 1})
      if [ -f "${lib.elemAt entry 1}" ]; then
        cp "${lib.elemAt entry 1}" $out/bin/
      fi
    '') toolPathList}

    # Platform-specific processing
    ${
      if isLinux then
        ''
          # Linux (ELF) processing
          # Patch ELF binaries
          for bin in $(ls -1 $out/bin); do
            if [ -f "$out/bin/$bin" ] && [ -x "$out/bin/$bin" ] && ${patchelf}/bin/patchelf --print-interpreter "$out/bin/$bin" 2>/dev/null; then
              # It's an ELF executable, patch it
              ${patchelf}/bin/patchelf --set-interpreter '$ORIGIN/../lib/ld-linux-x86-64.so.2' $out/bin/$bin
              ${patchelf}/bin/patchelf --force-rpath --set-rpath "${portableRPath}" $out/bin/$bin
            fi
          done

          # Collect all dependencies
          echo "Collecting dependencies for toolchain binaries..."
          BINARIES=($(ls -1 $out/bin))
          DEPS=()
          INTERP=""

          for bin in "''${BINARIES[@]}"; do
            if [ -f "$out/bin/$bin" ] && ${patchelf}/bin/patchelf --print-interpreter "$out/bin/$bin" 2>/dev/null; then
              # Get interpreter
              INTERP="$(${patchelf}/bin/patchelf --print-interpreter "$out/bin/$bin")"
              # Get shared library dependencies
              LIBS="$(${nixpkgs.glibc}/bin/ldd "$out/bin/$bin" | grep '=>' | awk '{print $3}' | grep -v 'not found')"
              if [ -n "$LIBS" ]; then
                DEPS+=($LIBS)
              fi
            fi
          done

          # Copy all dependencies to lib directory
          for dep in "''${DEPS[@]}"; do
            if [ -f "$dep" ]; then
              cp "$dep" $out/lib/
              # Patch the dependency to use relative paths
              ${patchelf}/bin/patchelf --force-rpath --set-rpath "${portableRPath}" $out/lib/$(basename "$dep")
            fi
          done

          # Copy the interpreter
          if [ -n "$INTERP" ] && [ -f "$INTERP" ]; then
            cp "$INTERP" $out/lib/
            ln -sf $(basename "$INTERP") $out/lib/ld-linux-x86-64.so.2
          fi
        ''
      else if isDarwin then
        ''
          # macOS (Mach-O) processing
          # Collect all dependencies using otool
          echo "Collecting dependencies for toolchain binaries..."
          BINARIES=($(ls -1 $out/bin))
          DEPS=()

          for bin in "''${BINARIES[@]}"; do
            if [ -f "$out/bin/$bin" ] && [ -x "$out/bin/$bin" ]; then
              # Check if it's a Mach-O binary
              if ${nixpkgs.file}/bin/file "$out/bin/$bin" | grep -q "Mach-O"; then
                # Get shared library dependencies
                LIBS="$(${nixpkgs.darwin.cctools}/bin/otool -L "$out/bin/$bin" | tail -n +2 | awk '{print $1}' | grep -v '^/usr/lib' | grep -v '^/System' | grep -v '^\@')"
                if [ -n "$LIBS" ]; then
                  echo "Found dependencies for $bin: $LIBS"
                  DEPS+=($LIBS)
                fi
                
                # Update the binary to use @executable_path relative paths
                for dep in $LIBS; do
                  if [ -f "$dep" ]; then
                    BASENAME=$(basename "$dep")
                    ${nixpkgs.darwin.cctools}/bin/install_name_tool -change "$dep" "@executable_path/../lib/$BASENAME" "$out/bin/$bin"
                  fi
                done
              fi
            fi
          done

          # Copy all dependencies to lib directory
          echo "Copying dependencies..."
          for dep in "''${DEPS[@]}"; do
            if [ -f "$dep" ]; then
              BASENAME=$(basename "$dep")
              echo "Copying $dep to $out/lib/$BASENAME"
              cp "$dep" $out/lib/
              
              # Update the internal ID of the library
              ${nixpkgs.darwin.cctools}/bin/install_name_tool -id "@loader_path/$BASENAME" "$out/lib/$BASENAME"
              
              # Update the library to use @loader_path for its dependencies
              if ${nixpkgs.file}/bin/file "$out/lib/$BASENAME" | grep -q "Mach-O"; then
                LIBDEPS="$(${nixpkgs.darwin.cctools}/bin/otool -L "$out/lib/$BASENAME" | tail -n +3 | awk '{print $1}' | grep -v '^/usr/lib' | grep -v '^/System' | grep -v '^\@')"
                for libdep in $LIBDEPS; do
                  if [ -f "$libdep" ]; then
                    LIB_BASENAME=$(basename "$libdep")
                    ${nixpkgs.darwin.cctools}/bin/install_name_tool -change "$libdep" "@loader_path/$LIB_BASENAME" "$out/lib/$BASENAME"
                  fi
                done
              fi
            fi
          done
        ''
      else
        ''
          # Unsupported platform
          echo "Unsupported platform: not Linux or macOS" >&2
          exit 1
        ''
    }

    # Generate the portable CC_TOOLCHAIN_INFO file
    cat > $out/CC_TOOLCHAIN_INFO << EOF
    ${lib.concatMapStringsSep "\n" (key: ''
      ${key}:${lib.concatStringsSep ":" (baseInfo.${key} or [ ])}
    '') (builtins.attrNames baseInfo)}
    EOF

    # Update TOOL_PATHS in CC_TOOLCHAIN_INFO to use the bundled paths
    TOOL_NAMES=(${lib.concatStringsSep " " toolNames})
    NEW_PATHS=()

    for name in "''${TOOL_NAMES[@]}"; do
      NEW_PATHS+=("$out/bin/$(basename $(grep "^TOOL_NAMES.*:.*$name" $out/CC_TOOLCHAIN_INFO | cut -d: -f$(grep -n "^TOOL_NAMES:.*$name" $out/CC_TOOLCHAIN_INFO | cut -d: -f3)))")
    done

    # Update TOOL_PATHS
    sed -i.bak "s|^TOOL_PATHS:.*|TOOL_PATHS:$(IFS=:; echo "''${NEW_PATHS[*]}")|" $out/CC_TOOLCHAIN_INFO
  '';

in
buildPortableToolchain
