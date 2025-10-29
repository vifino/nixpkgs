{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  util-linux,
  openssl,
  cacert,
  # The primary --enable-XXX variant. 'all' enables most features, but causes build-errors for some software,
  # requiring to build a special variant for that software. Example: 'haproxy'
  variant ? "all",
  extraConfigureFlags ? [ ],
  enableARMCryptoExtensions ? true,
  enableLto ? !(stdenv.hostPlatform.isStatic || stdenv.cc.isClang),
}:

let
  hasARMCryptoExtensions = stdenv.hostPlatform.isAarch64
    && ((builtins.match "^.*\\+crypto.*$" stdenv.hostPlatform.gcc.arch) != null);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "wolfssl-${variant}";
  version = "unstable-5.8.2-2025-10-28";

  src = fetchFromGitHub {
    owner = "wolfSSL";
    repo = "wolfssl";
    #tag = "v${finalAttrs.version}-stable";
    rev = "d7807d39e07e74460e05e388a7cbff9360874b21";
    hash = "sha256-zAb4yAqqv8GrIJdne7UfF+A6UM4D0hX+M89km9gUHQ8=";
  };

  postPatch = ''
    patchShebangs ./scripts
    # ensure test detects musl-based systems too
    substituteInPlace scripts/ocsp-stapling2.test \
      --replace '"linux-gnu"' '"linux-"'
  '';

  configureFlags = [
    "--enable-${variant}"
    "--enable-reproducible-build"
  ]
  ++ lib.optionals (variant == "all") [
    # Extra feature flags to add while building the 'all' variant.
    # Since they conflict while building other variants, only specify them for this one.
    "--enable-pkcs11"
    "--enable-writedup"
    "--enable-base64encode"
  ]
  ++ [
    # We're not on tiny embedded machines.
    # Increase TLS session cache from 33 sessions to 20k.
    "--enable-bigcache"

    # Use WolfSSL's Single Precision Math with timing-resistant cryptography.
    "--enable-sp=yes${
      lib.optionalString (stdenv.hostPlatform.isx86_64 || stdenv.hostPlatform.isAarch) ",asm"
    }"
    "--enable-sp-math-all"
    "--enable-harden"
  ]
  ++ lib.optionals (stdenv.hostPlatform.isx86_64) [
    # Enable AVX/AVX2/AES-NI instructions, gated by runtime detection via CPUID.
    "--enable-intelasm"
    "--enable-aesni"
  ]
  ++ lib.optionals (stdenv.hostPlatform.isAarch64) [
    # After 5.7.6 + PR 8325, there is ARM CPUID detection. It doesn't fall back with "inline" though,
    # so only enable it if explicitly enabled in the CPU target.
    (if enableARMCryptoExtensions
      then "--enable-armasm=${if hasARMCryptoExtensions then "inline" else "yes"}"
      else "--disable-armasm")
  ]
  ++ extraConfigureFlags;

  # Breaks tls13 tests on aarch64-darwin.
  hardeningDisable = lib.optionals (stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64) [
    "zerocallusedregs"
  ];

  # LTO should help with the C implementations.
  env.NIX_CFLAGS_COMPILE =
    (lib.optionalString (stdenv.hostPlatform.isAarch64 && enableARMCryptoExtensions && !hasARMCryptoExtensions)
      "-march=${stdenv.hostPlatform.gcc.arch}+crypto")
    + (lib.optionalString enableLto " -flto");

  env.NIX_LDFLAGS_COMPILE = lib.optionalString enableLto "-flto";

  # Don't attempt connections to external services in the test suite.
  env.WOLFSSL_EXTERNAL_TEST = "0";

  outputs = [
    "dev"
    "doc"
    "lib"
    "out"
  ];

  nativeBuildInputs = [
    autoreconfHook
    util-linux
  ];

  # FAILURES:
  #    497: test_wolfSSL_EVP_PBE_scrypt
  doCheck = !stdenv.hostPlatform.isLoongArch64;

  nativeCheckInputs = [
    openssl
    cacert
  ];

  postInstall = ''
    # fix recursive cycle:
    # wolfssl-config points to dev, dev propagates bin
    moveToOutput bin/wolfssl-config "$dev"
    # moveToOutput also removes "$out" so recreate it
    mkdir -p "$out"
  '';

  meta = {
    description = "Small, fast, portable implementation of TLS/SSL for embedded devices";
    mainProgram = "wolfssl-config";
    homepage = "https://www.wolfssl.com/";
    changelog = "https://github.com/wolfSSL/wolfssl/releases/tag/v${finalAttrs.version}-stable";
    platforms = lib.platforms.all;
    license = lib.licenses.gpl2Plus;
    maintainers = with lib.maintainers; [
      fab
      vifino
    ];
  };
})
