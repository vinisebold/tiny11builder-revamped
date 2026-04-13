# Comparativo: PRs Open (upstream) vs merges no fork

Data: 2026-04-13
Fork analisado: vinisebold/tiny11builder-revamped (branch main)
Upstream analisado: ntdevlabs/tiny11builder (PRs open)

## 1) Resultado da comparacao

PRs open no upstream: 22

- Ja incorporadas no fork (por commit/referencia de PR): 19
- Ainda nao incorporadas no fork: 3

### 1.1 Ja incorporadas no fork

#169, #273, #274, #289, #319, #344, #430, #449, #465, #488, #505, #509, #512, #518, #531, #534, #560, #581, #597.

### 1.2 Ainda nao incorporadas

- #475 - Apply to existing installation
- #444 - Support for non-English operating systems + bug fixes
- #335 - tiny11makerGUI v1.0.1

## 2) Tierlist de implementacao (pendentes)

## S Tier (alto valor, boa viabilidade com escopo controlado)

### PR #475 (implementacao parcial e isolada)

- Feature/fix: novo script para aplicar parte dos tweaks em instalacao ja existente.
- Por que vale: abre um segundo modo de uso (pos-instalacao) com alta utilidade para quem nao quer rebuild de ISO.
- Risco: alto se entrar no fluxo principal sem trilhos (pode degradar sistema em uso).
- Como implementar de forma segura:
  1. Nao acoplar ao tiny11maker/tiny11Coremaker.
  2. Introduzir como script separado com nome claro (ex.: Invoke-Tiny11Cleanup.ps1).
  3. Implementar modo dry-run (`-WhatIf`) e modo `-SafeProfile` por padrao.
  4. Incluir backup/export de chaves de registro antes de alterar.
  5. Bloquear operacoes destrutivas por padrao (servicos de update, remocoes irreversiveis).
  6. Documentar rollback minimo e matriz de suporte (builds/SKU).
- Decisao: Implementar, mas em perfil conservador e separado do core.

## A Tier (valor tecnico real, mas requer cherry-pick cirurgico)

### PR #444 (apenas trechos, nao merge integral)

- Feature/fix: compatibilidade com OS nao-ingles + varios bugfixes.
- Por que vale: reduz fragilidade em ambientes localizados e melhora portabilidade.
- Risco: diff muito grande (refatoracao ampla); alto risco de regressao no comportamento atual.
- Como implementar com baixo risco:
  1. Nao fazer merge direto.
  2. Extrair somente blocos de i18n realmente necessarios (SID em vez de nome localizado, rotinas robustas de path/registry).
  3. Rejeitar alteracoes de policy agressivas que mudam sem necessidade o fluxo atual.
  4. Testar em matrix minima: en-US, pt-BR, de-DE; 24H2/25H2.
  5. Commitar em pequenos passos tematicos.
- Decisao: Cherry-pick seletivo, nao merge completo.

## B Tier (opcional estrategico)

### PR #335 (GUI separada)

- Feature/fix: interface grafica para o processo.
- Por que pode valer: melhora UX para usuarios nao tecnicos.
- Risco: aumenta muito a superficie de manutencao (WinForms/UI state, logging, freeze de UI, fluxo paralelo).
- Como implementar se desejar:
  1. Manter como ferramenta separada (nao no fluxo core).
  2. Congelar contrato de chamadas para o script core (API interna).
  3. Adicionar validacoes de preflight e logs estruturados.
  4. Definir ownership/manutencao da GUI antes de publicar.
- Decisao: Opcional, melhor em repositorio/branch de ferramenta separada.

## 3) Recomendacao pratica (ordem sugerida)

1. #475 (faseado, perfil seguro, script separado).
2. #444 (cherry-pick de i18n e robustez em pequenos commits).
3. #335 (somente se houver interesse de produto GUI e mantenedor dedicado).

## 4) Nota sobre o estado atual do fork

Seu fork ja esta muito avancado em relacao aos open PRs do upstream: 19/22 estao incorporadas, incluindo quase todo o bloco de features/fixes de 2025-2026.
