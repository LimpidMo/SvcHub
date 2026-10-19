// srcDir 即 public 时（srcDir: 'public'），VitePress 硬编码复制 srcDir/public，不会带出 public/images；
// favicon 与 hero image 引用 /SvcHub/images/icon.png，构建后补拷进 dist
import { cpSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const docsRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const src = join(docsRoot, 'public', 'images')
const dest = join(docsRoot, '.vitepress', 'dist', 'images')

cpSync(src, dest, { recursive: true })
console.log(`copied ${src} -> ${dest}`)
