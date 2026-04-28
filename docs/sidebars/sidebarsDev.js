/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
module.exports = {
  devSidebar: [
    { type: "doc", id: "index", label: "Dev Overview" },
    {
      type: "category",
      label: "Architecture",
      collapsed: false,
      items: [
        "architecture/overview",
        "architecture/redemptions",
        "architecture/security-model",
      ],
    },
    {
      type: "category",
      label: "Smart Contracts",
      collapsed: false,
      items: ["contracts/ethereum", "contracts/optimism", "contracts/arbitrum"],
    },
    {
      type: "category",
      label: "Core Modules",
      collapsed: false,
      items: [
        {
          type: "category",
          label: "Liquid",
          collapsed: false,
          items: [
            "liquid/liquid-contract",
            {
              type: "category",
              label: "LiquidFeeVault",
              items: [
                "liquid/abstract-fee-vault-contract",
                "liquid/liquid-token-vault-contract",
                "liquid/liquid-eth-vault-contract",
              ],
            }
          ],
        },
        {
          type: "category",
          label: "MYT",
          collapsed: false,
          items: [
            "myt/myt-contract",
            {
              type: "category",
              label: "Operations",
              items: [
                "myt/permissioned-proxy-contract",
                "myt/liquid-allocator-contract",
                "myt/liquid-curator-contract",
              ],
            },
          ],
        },
        {
          type: "category",
          label: "Transmuter",
          collapsed: false,
          items: [
            "transmuter/transmuter-contract"
          ],
        },
      ],
    },
    {
      type: "category",
      label: "Integrating Liquid",
      collapsed: false,
      items: [
        "integration/using-lassets",
        "integration/integrate-myt",
        "integration/integrate-transmuter",
        "integration/integrate-liquid",
        "integration/grants-program",
      ],
    },
    "faq",
  ],
};
