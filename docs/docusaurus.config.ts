import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import {themes as prismThemes} from 'prism-react-renderer';

const repoUrl = 'https://github.com/RobertDeRose/nix-hex-box';
// The product page owns the site root; these docs are published beneath it at /docs/.
const siteRoot = 'https://robertderose.github.io/nix-hex-box/';

const config: Config = {
  title: 'HexBox',
  tagline: 'A Linux builder for Nix that lives in a box on your Mac',
  favicon: 'img/favicon.png',
  url: 'https://robertderose.github.io',
  baseUrl: '/nix-hex-box/docs/',
  trailingSlash: false,

  onBrokenLinks: 'throw',
  onBrokenAnchors: 'throw',

  markdown: {
    // .md pages are CommonMark; only .mdx pages are parsed as MDX.
    format: 'detect',
    hooks: {
      onBrokenMarkdownLinks: 'throw',
      onBrokenMarkdownImages: 'throw',
    },
  },
  themes: [
    [
      '@easyops-cn/docusaurus-search-local',
      {hashed: true, docsDir: 'src', docsRouteBasePath: '/', indexBlog: false, indexPages: false},
    ],
  ],

  // Site code lives in site/ because src/ is the documentation content.
  staticDirectories: ['site/static'],
  clientModules: ['./site/client/theme-color.ts'],

  presets: [
    [
      'classic',
      {
        docs: {
          path: 'src',
          routeBasePath: '/',
          sidebarPath: './sidebars.ts',
          editUrl: `${repoUrl}/edit/main/docs/`,
        },
        blog: false,
        pages: false,
        theme: {customCss: './site/css/custom.css'},
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    // The product page publishes the wide share image; the docs reuse it.
    image: 'https://robertderose.github.io/nix-hex-box/assets/social-preview.png',
    metadata: [
      {property: 'og:site_name', content: 'HexBox'},
      {property: 'og:image:alt', content: 'HexBox: Hex the Platypus, a Linux builder for Nix that naps in an Apple container on your Mac, shown packing Git and Helix packages inside a glass display case.'},
    ],
    colorMode: {respectPrefersColorScheme: true},
    navbar: {
      title: 'HexBox',
      // The logo returns to the product page, outside this Docusaurus site.
      logo: {alt: 'HexBox logo', src: 'img/favicon.png', href: siteRoot, target: '_self'},
      items: [
        {type: 'docSidebar', sidebarId: 'docs', label: 'Docs', position: 'left'},
        {href: siteRoot, label: 'Home', position: 'left', target: '_self'},
        {href: repoUrl, label: 'GitHub', position: 'right'},
      ],
    },
    footer: {
      links: [
        {label: 'Home', href: siteRoot, target: '_self'},
        {label: 'Source', href: repoUrl},
        {label: 'Releases', href: `${repoUrl}/releases`},
      ],
      copyright: 'Not maintained or endorsed by Apple or the NixOS project.',
    },
    docs: {sidebar: {hideable: true}},
    prism: {
      // Code blocks are dark in both themes, like the product page's terminal blocks.
      theme: prismThemes.vsDark,
      darkTheme: prismThemes.vsDark,
      additionalLanguages: ['nix', 'bash'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
