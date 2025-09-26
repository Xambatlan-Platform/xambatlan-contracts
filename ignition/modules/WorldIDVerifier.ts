import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const permit2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const morpho = "0xE741BC7c34758b4caE05062794E8Ae24978AF432";
const usdc = "0x79A02482A880bCE3F13e09Da970dC34db4CD24d1";

// Configuración para mercado USDC en Morpho Blue World Chain
const marketParams = {
  loanToken: usdc,                    // USDC como token de préstamo
  collateralToken: usdc,              // USDC como colateral (mismo token)
  oracle: "0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766",
  irm: "0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC",
  lltv: 950000000000000000,
};

export default buildModule("WorldIDVerifierModule", (m) => {
  const owner = m.getAccount(1);
  const worldIdVerifier = m.contract("WorldIDVerifier", [owner]);

  const userRegistry = m.contract("UserRegistry", [owner, worldIdVerifier]);

  const escrowWithLending = m.contract("EscrowWithLending", [owner, permit2, morpho]);
  m.call(escrowWithLending, "allowToken", [usdc, marketParams]);

  const serviceMarketplace = m.contract("ServiceMarketplace", [owner, userRegistry, escrowWithLending]);
 
  return { worldIdVerifier, userRegistry, escrowWithLending, serviceMarketplace };
});
