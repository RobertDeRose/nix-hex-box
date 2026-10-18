import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docs: [
    'introduction',
    {
      type: 'category',
      label: 'Getting Started',
      collapsed: false,
      items: ['getting-started/overview', 'getting-started/installation', 'getting-started/configuration'],
    },
    {
      type: 'category',
      label: 'Architecture',
      items: ['architecture/runtime-model', 'architecture/generated-files', 'architecture/networking'],
    },
    {
      type: 'category',
      label: 'Operations',
      items: ['operations/verification', 'operations/logs', 'operations/troubleshooting'],
    },
    {
      type: 'category',
      label: 'Reference',
      items: ['reference/options', 'reference/design-notes'],
    },
  ],
};

export default sidebars;
