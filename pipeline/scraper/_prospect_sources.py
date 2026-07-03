import asyncio, httpx

BROWSER_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
    'Accept-Language': 'pt-BR,pt;q=0.9',
}

async def test_url(name, url, timeout=15.0):
    result = {'name': name, 'url': url, 'status': 0, 'content_type': '', 'size': 0, 'has_table': False, 'has_json': False, 'is_pdf': False, 'error': ''}
    try:
        async with httpx.AsyncClient(headers=BROWSER_HEADERS, timeout=timeout, follow_redirects=True, verify=False) as client:
            r = await client.get(url)
            result['status'] = r.status_code
            result['content_type'] = r.headers.get('content-type', '')[:60]
            result['size'] = len(r.content)
            ct = result['content_type'].lower()
            if 'pdf' in ct:
                result['is_pdf'] = True
            elif 'json' in ct:
                result['has_json'] = True
            elif 'html' in ct:
                text = r.text.lower()
                result['has_table'] = any(m in text for m in ['<table', '<tr>', '<td', 'cotacao', 'preco', 'produto', 'hortifruti'])
    except Exception as e:
        result['error'] = str(e)[:80]
    return result

async def main():
    urls = [
        ('Agrolink CEASA SP', 'https://www.agrolink.com.br/cotacoes/ceasa/ceasa---sp/'),
        ('CEPEA Banco Dados', 'https://cepea.org.br/br/consultas-ao-banco-de-dados-do-site.aspx'),
        ('CEAGESP Cotacao', 'https://ceagesp.gov.br/cotacoes/#cotacao'),
        ('Calculadora Rural', 'https://calculadorarural.com.br/ceasa'),
        ('CEASA PR Hoje', 'https://celepar7.pr.gov.br/ceasa/hoje.asp'),
        ('CONAB Pentaho API', 'https://pentahoportaldeinformacoes.conab.gov.br/pentaho/api/repos/%3Ahome%3APROHORT%3AprecoDia.wcdf/generatedContent?userid=pentaho&password=password'),
        ('CEASA ES', 'http://200.198.51.71/detec/boletim_completo_es/boletim_completo_es.php'),
        ('CEASA MG Minas1', 'https://minas1.ceasa.mg.gov.br/ceasainternet/cst_precosmaiscomumEstados/cst_precosmaiscomumEstados.php'),
        ('CEASA PE', 'https://www.ceasape.org.br/cotacao/hortalicas?data=06/01/2025'),
        ('CEASA RN', 'https://transparencia.ceasa.rn.gov.br/cotacoes'),
        ('CEASA MS 2025', 'https://www.ceasa.ms.gov.br/boletim-2025/'),
        ('CEASA MS 2026', 'https://www.ceasa.ms.gov.br/boletim-2026/'),
        ('CEASA PR 2025', 'https://www.ceasa.pr.gov.br/Pagina/Cotacao-Diaria-de-Precos-2025'),
        ('Goias Procon PDF', 'https://goias.gov.br/procon/wp-content/uploads/sites/19/2017/03/hortifrutti-2017.pdf'),
    ]
    results = await asyncio.gather(*[test_url(n, u) for n, u in urls])
    print('=' * 85)
    print('PROSPECCAO DE FONTES - TESTE DE CONECTIVIDADE')
    print('=' * 85)
    for r in results:
        icon = 'OK' if r['status'] == 200 else ('XX' if r['error'] else str(r['status']))
        table = 'TAB' if r['has_table'] else '---'
        pdf = 'PDF' if r['is_pdf'] else '---'
        js = 'JSON' if r['has_json'] else '---'
        size = '%dKB' % (r['size']/1024) if r['size'] else 'N/A'
        print('  [%s] %-30s HTTP %-3s %7s %s %s %s' % (icon, r['name'], r['status'], size, table, pdf, js))
        if r['error']:
            print('        ERRO: %s' % r['error'])

asyncio.run(main())