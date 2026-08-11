import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import mdx from "@astrojs/mdx";
const image = "https://oss.greenways.ai/visual-language/assets/og-ignatius.jpg";
export default defineConfig({
  site: "https://oss.greenways.ai", base: "/ignatius", vite: { build: { assetsInlineLimit: 0 } },
  integrations: [starlight({
    title: "Ignatius", description: "The authoritative PostgreSQL chain for Greenways.", favicon: "https://oss.greenways.ai/visual-language/favicons/ignatius.svg",
    components: { Header: "./src/components/SharedSiteHeader.astro", ThemeProvider: "./src/components/GreenwaysThemeProvider.astro", ThemeSelect: "./src/components/GreenwaysThemeSelect.astro" },
    customCss: ["./src/styles/custom.css", "./src/styles/starlight-shell.css"], social: [{ icon: "github", label: "GitHub", href: "https://github.com/greenways-ai/ignatius" }], editLink: { baseUrl: "https://github.com/greenways-ai/ignatius/edit/main/site/" }, lastUpdated: true, pagefind: true, tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
    sidebar: [
      { label: "Overview", slug: "index" },
      { label: "Getting started", items: [{ label: "Introduction", slug: "getting-started" }, { label: "PostgreSQL chain", slug: "getting-started/postgres" }, { label: "Development workflow", slug: "getting-started/development" }] },
      { label: "Concepts", items: [{ label: "Authority boundary", slug: "concepts/authority-boundary" }, { label: "Canonical records", slug: "concepts/canonical-records" }, { label: "Transactions & receipts", slug: "concepts/transactions" }, { label: "Storage", slug: "concepts/storage" }, { label: "Contracts & actors", slug: "concepts/contracts-actors" }] },
      { label: "Guides", items: [{ label: "Agent workflows", slug: "guides/agent-workflows" }, { label: "Git integration", slug: "guides/git" }, { label: "Workspace lifecycle", slug: "guides/workspaces" }, { label: "Build timelines", slug: "guides/build-timelines" }] },
      { label: "Reference", items: [{ label: "Chain API", slug: "reference/chain-api" }, { label: "Repository layout", slug: "reference/repository" }] },
      { label: "Project", items: [{ label: "Status & roadmap", slug: "project/status" }, { label: "Contributing", slug: "project/contributing" }, { label: "Source ↗", link: "https://github.com/greenways-ai/ignatius" }, { label: "Greenways OSS ↗", link: "https://oss.greenways.ai/" }] }
    ],
    head: [{ tag:"meta",attrs:{property:"og:image",content:image}},{tag:"meta",attrs:{property:"og:image:secure_url",content:image}},{tag:"meta",attrs:{property:"og:image:type",content:"image/jpeg"}},{tag:"meta",attrs:{property:"og:image:width",content:"1200"}},{tag:"meta",attrs:{property:"og:image:height",content:"630"}},{tag:"meta",attrs:{property:"og:image:alt",content:"Ignatius's sealed arch over an ordered civic nave"}},{tag:"meta",attrs:{name:"twitter:card",content:"summary_large_image"}},{tag:"meta",attrs:{name:"twitter:image",content:image}}]
  }), mdx()]
});
