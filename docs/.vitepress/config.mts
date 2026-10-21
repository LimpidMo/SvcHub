import { defineConfig } from 'vitepress'

// 中文 = root locale，英文 = /en/ 前缀 locale；GitHub Pages 项目页固定 /SvcHub/ 前缀
export default defineConfig({
  base: '/SvcHub/',
  // 站点源文件在 docs/public/：避开 docs/superpowers/ 被扫描，md 与静态资源 public/images 同处一站
  srcDir: 'public',
  title: 'SvcHub',
  head: [
    ['link', { rel: 'icon', type: 'image/png', href: '/SvcHub/images/icon.png' }],
    ['meta', { name: 'theme-color', content: '#3aa275' }]
  ],
  lastUpdated: true,
  locales: {
    root: {
      label: '简体中文',
      lang: 'zh-CN',
      themeConfig: {
        nav: [
          { text: '首页', link: '/' },
          { text: '指南', link: '/guide/' },
          { text: '开发', link: '/dev/' },
          { text: '更新日志', link: '/guide/changelog' },
          { text: 'GitHub', link: 'https://github.com/LimpidMo/SvcHub' }
        ],
        sidebar: {
          '/guide/': [
            {
              text: '指南',
              items: [
                { text: '简介', link: '/guide/' },
                { text: '启停功能', link: '/guide/features' },
                { text: '巡检保活', link: '/guide/keepalive' },
                { text: '服务配置示例', link: '/guide/examples' },
                { text: '注意事项', link: '/guide/notes' },
                { text: '常见问题', link: '/guide/faq' }
              ]
            },
            {
              text: '服务配置参考',
              items: [
                { text: 'Termux 服务', link: '/guide/termux' },
                { text: '二进制服务', link: '/guide/binary' }
              ]
            },
            {
              text: '其他',
              items: [
                { text: '更新日志', link: '/guide/changelog' }
              ]
            }
          ],
          '/dev/': [
            {
              text: '开发',
              items: [
                { text: '本地开发联调', link: '/dev/' },
                { text: '模块构建', link: '/dev/build' }
              ]
            }
          ],
        },
        outline: [2, 3],
        docFooter: { prev: '上一页', next: '下一页' },
        lastUpdatedText: '最后更新',
        returnToTopLabel: '回到顶部',
        sidebarMenuLabel: '菜单',
        darkModeSwitchLabel: '主题',
        lightModeSwitchTitle: '切换到浅色模式',
        darkModeSwitchTitle: '切换到深色模式',
        // changelog 仅中文单页：语言切换按当前页路径推导会生成 /en/changelog.html 404，
        // 关掉对应链接后切换一律回各语言首页（nav 的 changelog 入口已单独指向中文页）
        i18nRouting: false
      }
    },
    en: {
      label: 'English',
      lang: 'en-US',
      link: '/en/',
      themeConfig: {
        nav: [
          { text: 'Home', link: '/en/' },
          { text: 'Guide', link: '/en/guide/' },
          { text: 'Development', link: '/en/dev/' },
          { text: 'Changelog', link: '/guide/changelog' },
          { text: 'GitHub', link: 'https://github.com/LimpidMo/SvcHub' }
        ],
        sidebar: {
          '/en/guide/': [
            {
              text: 'Guide',
              items: [
                { text: 'Introduction', link: '/en/guide/' },
                { text: 'Start/Stop Services', link: '/en/guide/features' },
                { text: 'Patrol Keep-alive', link: '/en/guide/keepalive' },
                { text: 'Service Examples', link: '/en/guide/examples' },
                { text: 'Notes', link: '/en/guide/notes' },
                { text: 'FAQ', link: '/en/guide/faq' }
              ]
            },
            {
              text: 'Service Configuration',
              items: [
                { text: 'Termux Service', link: '/en/guide/termux' },
                { text: 'Binary Service', link: '/en/guide/binary' }
              ]
            },
            {
              text: 'Other',
              items: [
                { text: 'Changelog', link: '/guide/changelog' }
              ]
            }
          ],
          '/en/dev/': [
            {
              text: 'Development',
              items: [
                { text: 'Local Development', link: '/en/dev/' },
                { text: 'Module Build', link: '/en/dev/build' }
              ]
            }
          ],
        },
        outline: [2, 3],
        // 同中文侧：changelog 仅中文单页，语言切换一律回首页（见 root locale 注释）
        i18nRouting: false
      }
    }
  }
})
