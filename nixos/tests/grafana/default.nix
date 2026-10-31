{
  runTest,
}:

{
  basic = runTest ./basic.nix;
  data-dir = runTest ./data-dir.nix;
  provision = runTest ./provision;
}
