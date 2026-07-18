# Regras de Arquitetura - Stack: PWA + FastAPI + Playwright

## Delegacao de Subagentes
- Se a tarefa envolve manipulacao de DOM, seletores web, extracao de dados ou scripts de automacao: **DELEGUE EXCLUSIVAMENTE AO SUBAGENTE `@scraper-subagent`**.
- Se a tarefa envolve interface, componentes React, Service Workers, Vite ou IndexedDB: **DELEGUE EXCLUSIVAMENTE AO SUBAGENTE `@pwa-subagent`**.
- **Nunca** misture logica de execucao de browser (Playwright) dentro de codigo de renderizacao do frontend.

## Diretrizes Python (FastAPI + Playwright)
- Todo endpoint que acione o Playwright deve ser assincrono (`async def`) e rodar em uma `BackgroundTask` ou fila separada para nao bloquear o Event Loop do FastAPI.
- E obrigatorio o uso de tipagem estrita com `Pydantic` em todas as entradas e saidas de rotas.

## Diretrizes PWA (React + Vite)
- O estado da interface deve ser derivado do Banco de Dados Local. Nao faca requisicoes HTTP diretas para renderizar a UI se o dado ja puder existir no cache local (Padrao Stale-While-Revalidate).
