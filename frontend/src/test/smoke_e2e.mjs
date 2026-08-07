import { chromium } from 'playwright'

const BASE = process.env.SMOKE_BASE_URL || 'http://127.0.0.1:5173'
const results = { ok: true, checks: [] }

function check(name, ok, detail = '') {
  results.checks.push({ name, ok, detail })
  if (!ok) results.ok = false
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ' — ' + detail : ''}`)
}

const browser = await chromium.launch()
const page = await browser.newPage()
const consoleErrors = []
page.on('console', (msg) => {
  if (msg.type() === 'error') consoleErrors.push(msg.text())
})
page.on('pageerror', (err) => consoleErrors.push(String(err)))

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 30000 })

  // Aguarda a UI carregar (cards ou grade)
  await page.waitForTimeout(4000)

  // 1. App renderizou
  const bodyText = (await page.textContent('body')) || ''
  check('App renderiza', bodyText.length > 100, `${bodyText.length} chars`)

  // 2. Aba Grade Sazonal — clica na tab
  const gradeTab = page.getByRole('tab', { name: /Grade Sazonal/i })
  if (await gradeTab.count()) {
    await gradeTab.click()
    await page.waitForTimeout(4000)
  }

  // 3. Tooltips de gap NÃO devem existir
  const gapTooltip = await page.getByText(/CONAB não publicou dados|scraper pendente/i).count()
  check('Sem tooltips de gap estrutural/coleta', gapTooltip === 0, `${gapTooltip} encontrados`)

  // 4. Ícones (i) de transparência presentes (badges de ano ou tooltips)
  const infoIcons = await page.getByRole('button', { name: /Informação de transparência/i }).count()
  const yearBadges = await page.locator('text=/^\'\\d{2}$/').count()
  check(
    'Ícones (i) ou badges de ano âncora presentes',
    infoIcons > 0 || yearBadges > 0,
    `i=${infoIcons}, badges=${yearBadges}`,
  )

  // 5. Sem R$ no DOM
  const rleak = await page.locator('text=R$').count()
  check('Sem R$ no DOM', rleak === 0, `${rleak} ocorrências`)

  // 6. Badges de transparência no card ("Coleta Efetiva" / "Histórico Real")
  const coletaEfetiva = await page.getByText(/Coleta Efetiva/i).count()
  const historicoReal = await page.getByText(/Histórico Real/i).count()
  check(
    'Badges de tipo de dado (Coleta Efetiva / Histórico Real)',
    coletaEfetiva > 0 || historicoReal > 0,
    `coleta=${coletaEfetiva}, historico=${historicoReal}`,
  )

  // 7. Sem badges sintéticos 📊/🪄
  const sintetico = await page.locator('text=/📊 Estimativa|🪄 Estimado/').count()
  check('Sem badges sintéticos 📊/🪄', sintetico === 0, `${sintetico} encontrados`)
} catch (err) {
  check('Navegação/execução', false, String(err))
}

check('Sem erros de console', consoleErrors.length === 0, consoleErrors.slice(0, 3).join(' | '))

await browser.close()
console.log(JSON.stringify({ summary: results.ok ? 'PASS' : 'FAIL', checks: results.checks }, null, 2))
process.exit(results.ok ? 0 : 1)
