// @ts-check
// `@type` JSDoc annotations allow editor autocompletion and type checking
// (when paired with `@ts-check`).
// There are various equivalent ways to declare your Docusaurus config.
// See: https://docusaurus.io/docs/api/docusaurus-config

import { themes as prismThemes } from "prism-react-renderer";

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "Liquid Protocol",
  tagline: "Self-repaying loans powered by yield-bearing collateral on Lux Network",
  favicon: "img/favicon.png",

  // Set the production url of your site here
  url: "https://liquid.lux.network",
  // Set the /<baseUrl>/ pathname under which your site is served
  // For GitHub pages deployment, it is often '/<projectName>/'
  baseUrl: "/",

  // GitHub pages deployment config.
  organizationName: "luxfi",
  projectName: "liquid-docs",

  onBrokenLinks: "throw",
  onBrokenMarkdownLinks: "warn",

  // Even if you don't use internationalization, you can use this field to set
  // useful metadata like html lang. For example, if your site is Chinese, you
  // may want to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  markdown: {
    mermaid: true,
  },
  themes: [
    "@docusaurus/theme-mermaid",
    [
      require.resolve("@easyops-cn/docusaurus-search-local"),
      {
        hashed: true,
        docsRouteBasePath: ["user", "dev", "governance", "projects"],
        highlightSearchTermsOnTargetPage: true,
        explicitSearchResultPath: true,
      },
    ],
  ],

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          id: "default",
          path: "docs/user",
          routeBasePath: "user",
          sidebarPath: require.resolve("./sidebars/sidebarsUser.js"),
          editUrl:
            "https://github.com/luxfi/liquid/edit/main/docs/",
          showLastUpdateAuthor: true,
          showLastUpdateTime: true,
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
      }),
    ],
  ],

  plugins: [
    // — DEV docs @ /dev
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "dev",
        path: "docs/dev",
        routeBasePath: "dev",
        sidebarPath: require.resolve("./sidebars/sidebarsDev.js"),
        editUrl:
          "https://github.com/luxfi/liquid/edit/main/docs/docs/dev/",
        showLastUpdateAuthor: true,
        showLastUpdateTime: true,
      },
    ],

    // — Governance docs @ /governance
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "governance",
        path: "docs/governance",
        routeBasePath: "governance",
        sidebarPath: require.resolve("./sidebars/sidebarsGovernance.js"),
        editUrl:
          "https://github.com/luxfi/liquid/edit/main/docs/docs/governance/",
        showLastUpdateAuthor: true,
        showLastUpdateTime: true,
      },
    ],

    // — PROJECTS docs @ /projects
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "projects",
        path: "docs/projects",
        routeBasePath: "projects",
        sidebarPath: require.resolve("./sidebars/sidebarsProjects.js"),
        editUrl:
          "https://github.com/luxfi/liquid/edit/main/docs/docs/projects/",
        showLastUpdateAuthor: true,
        showLastUpdateTime: true,
      },
    ],

    // Redirect  root `/` → `/user`
    [
      "@docusaurus/plugin-client-redirects",
      {
        redirects: [
          {
            from: "/",
            to: "/user",
          },
        ],
      },
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      announcementBar: {
        id: "beta-2025-audit",
        content:
          "These docs are in active development. Expect gaps and changes. " +
          '<a href="https://discord.gg/luxdefi">Get support</a> · ' +
          '<a href="https://github.com/luxfi/liquid/issues/new">Report an issue</a>',
        backgroundColor: "#111111",
        textColor: "#ffffff",
        isCloseable: false,
      },
      image: "img/social-card.png",
      colorMode: {
        defaultMode: "dark", // start in dark
        disableSwitch: true, // hide the light/dark toggle
        respectPrefersColorScheme: false, // ignore OS preference
      },
      navbar: {
        logo: {
          alt: "Liquid Protocol",
          src: "img/logo.svg",
          href: "/user",
        },
        items: [
          {
            type: "docSidebar",
            sidebarId: "tutorialSidebar",
            position: "left",
            label: "Users",
          },
          {
            type: "docSidebar",
            sidebarId: "devSidebar",
            docsPluginId: "dev",
            position: "left",
            label: "Developers",
          },
          {
            type: "docSidebar",
            sidebarId: "tutorialSidebar",
            docsPluginId: "governance",
            position: "left",
            label: "Governance",
          },
          {
            type: "docSidebar",
            sidebarId: "tutorialSidebar",
            docsPluginId: "projects",
            position: "left",
            label: "Integrations",
          },
          {
            href: "https://github.com/luxfi/liquid",
            label: "GitHub",
            position: "right",
          },
        ],
      },
      footer: {
        style: "dark",
        links: [
          {
            title: "Documentation",
            items: [
              {
                label: "User",
                to: "/user",
              },
              {
                label: "Developer",
                to: "/dev",
              },
              {
                label: "Governance",
                to: "/governance/intro",
              },
              {
                label: "Integrations",
                to: "/projects",
              },
            ],
          },
          {
            title: "Community",
            items: [
              {
                label: "Launch App",
                href: "https://app.lux.finance",
              },
              {
                label: "Discord",
                href: "https://discord.gg/luxdefi",
              },
              {
                label: "X",
                href: "https://x.com/LiquidFi",
              },
            ],
          },
          {
            title: "More",
            items: [
              {
                label: "GitHub",
                href: "https://github.com/luxfi",
              },
              {
                label: "Lux Network",
                href: "https://lux.network",
              },
              {
                label: "DefiLlama",
                href: "https://defillama.com/",
              },
            ],
          },
        ],
        logo: {
          alt: "Liquid Protocol",
          src: "img/logo.svg",
          href: "https://lux.finance",
          width: 160,
        },
        copyright: `Copyright \u00a9 2020 \u2013 ${new Date().getFullYear()} Lux Partners.
        <br>
        <span style="font-size: 0.6em; opacity: 0.8;">
        All rights reserved, no guarantees given. DeFi tools are not toys. Use at your own risk.
      </span>`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
      },
    }),
};

export default config;
