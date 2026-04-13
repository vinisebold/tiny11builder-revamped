# Auditoria de Pull Requests do repositório ntdevlabs/tiny11builder

Data da reavaliacao: 2026-04-13
Repositorio auditado: ntdevlabs/tiny11builder (upstream)
Escopo total: 93 PRs

- Open: 22
- Merged: 20
- Closed sem merge: 51 (71 closed totais no GitHub menos 20 merged)

## 1) Metodo (reavaliacao aprofundada)

- Coleta atualizada via gh CLI (`gh pr list`, `gh pr view`, `gh pr diff`).
- Reconferencia do estado aberto/fechado/merged e mergeability atual (`MERGEABLE` vs `CONFLICTING`).
- Revisao tecnica de risco em todas as PRs open por:
  - superficie de seguranca (download externo, execution policy, alteracoes de servico e registro);
  - risco de regressao funcional (mudancas amplas, refatoracao extensa, fluxo interativo);
  - compatibilidade (24H2/25H2, OOBE, TaskCache, ADK/oscdimg).
- Reconferencia do documento anterior e consolidacao de deltas.

## 2) Delta em relacao ao audit anterior

- O estado do upstream permanece com 22 PRs open.
- Mergeability atual nas open:
  - 18 `MERGEABLE`
  - 4 `CONFLICTING` (#273, #274, #289, #344)
- O principal delta pratico foi no seu fork (vinisebold/tiny11builder-revamped): as PRs prioritarias e condicionais selecionadas foram integradas localmente e publicadas, mas o upstream segue sem essas PRs mergeadas.

## 3) Resumo executivo

- Nao ha evidencia de malware/backdoor nas PRs abertas analisadas.
- Ha comandos sensiveis em varias PRs (normal para este tipo de projeto), especialmente registry/service hardening e bypass de instalacao.
- O maior risco nao e malicia, e regressao de comportamento por PRs grandes, antigas ou com refatoracao excessiva.
- A triagem continua valida:
  - Merge rapido (baixo risco): docs/fixes pequenos e correcoes pontuais de compatibilidade.
  - Merge condicionado: PRs com fluxo interativo novo, mudancas em execucao/elevacao, ou politicas de IA/servicos.
  - Nao mergear direto no core: PRs com escopo paralelo (GUI) ou mudancas amplas destrutivas.

## 4) Matriz aprofundada das PRs OPEN (estado upstream atual)

| PR   | Escopo                                     | Mergeability | Risco tecnico | Observacoes aprofundadas                                                                                                        | Decisao                                 |
| ---- | ------------------------------------------ | ------------ | ------------- | ------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| #597 | Selecao de apps para remover               | MERGEABLE    | Medio         | Boa UX de selecao, mas sobrepoe fluxo custom existente e pode divergir da lista externa (`removePackage.txt`) sem sincronizacao | Merge com ajuste                        |
| #581 | README (reabilitar features)               | MERGEABLE    | Baixo         | Documentacao util e segura                                                                                                      | Merge recomendado                       |
| #560 | Hardening e robustez tiny11maker           | MERGEABLE    | Baixo         | Melhora tratamento de erro e resiliencia operacional                                                                            | Merge recomendado                       |
| #534 | Adicionar Edge a lista de remocao          | MERGEABLE    | Medio         | Impacto funcional alto para usuarios que dependem do Edge; precisa ser opcional/configuravel                                    | Merge com ajuste                        |
| #531 | Politicas IA (Notepad/Recall)              | MERGEABLE    | Baixo/Medio   | Politicas legitimas; validar efeito por build e disponibilidade de chave                                                        | Merge com validacao por build           |
| #518 | Fallback elevacao admin                    | MERGEABLE    | Medio         | Mudanca pequena mas sensivel no relaunch; revisar argumentos (`-NoExit`, quoting)                                               | Merge com ajuste                        |
| #512 | Disable Search Highlights                  | MERGEABLE    | Baixo         | Mudanca de politica simples, baixo risco de regressao                                                                           | Merge recomendado                       |
| #509 | README numeracao                           | MERGEABLE    | Baixo         | Apenas docs                                                                                                                     | Merge recomendado                       |
| #505 | README wording                             | MERGEABLE    | Baixo         | Apenas docs                                                                                                                     | Merge recomendado                       |
| #488 | README instrucoes e numeracao              | MERGEABLE    | Baixo         | Apenas docs                                                                                                                     | Merge recomendado                       |
| #475 | Aplicar em instalacao existente            | MERGEABLE    | Medio/Alto    | Novo modo operacional, superficie sensivel e potencial de dano em sistema em uso                                                | Nao mergear no core sem hardening forte |
| #465 | Debloat interativo (`-Custom`)             | MERGEABLE    | Medio         | Valor alto, mas exige UX robusta, validacao de input e coerencia com regras de politicas condicionais                           | Merge com testes                        |
| #449 | Externaliza lista para `removePackage.txt` | MERGEABLE    | Baixo         | Boa manutencao; precisa fallback se arquivo ausente/vazio                                                                       | Merge com ajuste pequeno                |
| #444 | Suporte non-English + bug fixes            | MERGEABLE    | Alto          | Diff muito grande, altera fluxos centrais e politicas de execucao; alto risco de regressao silenciosa                           | Requer refatoracao antes de merge       |
| #430 | Coremaker robustness fixes                 | MERGEABLE    | Baixo         | Melhorias pontuais de robustez e fluxo                                                                                          | Merge recomendado                       |
| #344 | Auto mount ISO / auto drive letter         | CONFLICTING  | Medio         | Ideia boa, mas historicamente com bug de validacao no loop; precisa correcoes                                                   | Merge com ajuste obrigatorio            |
| #335 | tiny11makerGUI v1.0.1                      | MERGEABLE    | Medio         | Grande escopo paralelo (produto novo) e aumento de superficie                                                                   | Nao mergear direto no core              |
| #319 | oscdimg/exec policy/compressao/Run.bat     | MERGEABLE    | Medio         | PR util, mas ampla e com partes de estilo/execucao que precisam curadoria seletiva                                              | Merge com ajustes/testes                |
| #289 | GUIDs TaskCache para 24H2                  | CONFLICTING  | Baixo         | Correcao importante para compatibilidade por versao; conflito e apenas de base antiga                                           | Merge recomendado (adaptado)            |
| #274 | Prompt disable driver auto install         | CONFLICTING  | Baixo         | Valor funcional bom; precisa parser robusto para y/yes/n/no/enter                                                               | Merge com ajuste                        |
| #273 | Disable Spotlight lockscreen/tips          | CONFLICTING  | Baixo         | Tweaks simples e previsiveis                                                                                                    | Merge recomendado                       |
| #169 | OOBE/installer skips adicionais            | MERGEABLE    | Baixo/Medio   | Pode alterar fluxo de provisionamento corporativo; ideal tornar opcional e schema-safe no unattend                              | Merge com ajuste                        |

## 5) Seguranca: sinais encontrados e interpretacao

Padroes sensiveis observados nas open (sem indicio de malicia por si):

- `Set-ExecutionPolicy` / relaunch elevado.
- Alteracoes de registro em politicas de Windows/Explorer/Teams/Outlook/WindowsAI.
- Ajustes em servicos/tarefas (`TaskCache`, `wuauserv`, `WaaSMedicSVC`, `UsoSvc`) em PRs maiores.
- Download de binario utilitario (`oscdimg.exe`) de endpoint Microsoft em algumas PRs.

Interpretacao tecnica:

- Esses padroes sao coerentes com debloat/tuning de imagem offline.
- O risco principal e operacional (regressao, quebra de update/servicing, UX degradada), nao exfiltracao.
- PRs muito extensas (especialmente #444, #475, #335) devem passar por merge seletivo por blocos, nunca merge direto.

## 6) Compatibilidade 24H2/25H2 (foco especifico)

Pontos criticos:

- TaskCache GUIDs variam por release (24H2+). PR #289 e relevante.
- Politicas de IA/Recall (#531) podem ter efeito diferente por build/SKU.
- Fluxo OOBE/unattend (#169) exige aderencia de schema e fallback seguro.

Recomendacao de compatibilidade:

- Manter logica condicional por versao para GUIDs/task cleanup.
- Tratar politicas novas como best-effort (nao falhar build se chave nao existir).
- Evitar hardcoding fraco em passos de setup e mount.

## 7) Cobertura das 93 PRs (objetiva)

### 7.1 Merged (20)

- Base upstream estavel historica (ex.: #441, #419, #395, #277, #268, #246, #197, #195).
- Decisao: sincronizar/cherry-pick conforme divergencia do fork.

### 7.2 Closed sem merge (51)

- Predominam PRs stale, supersedidas, experimentais ou de escopo paralelo.
- Decisao: nao mergear direto; apenas cherry-pick cirurgico quando houver ganho claro e risco baixo.

### 7.3 Open (22)

- Classificacao final da reavaliacao:
  - Merge recomendado: #273, #289, #430, #488, #505, #509, #512, #560, #581
  - Merge com ajuste/testes: #169, #274, #319, #344, #449, #465, #518, #531, #534, #597
  - Nao mergear direto no core: #335, #444, #475

## 8) Guia de merge seguro (curto)

- Priorizar PR pequena e isolada primeiro.
- Em PR antiga/conflitante: preservar fluxo atual e portar apenas blocos de valor.
- Sempre validar:
  - ausencia de marcadores de merge;
  - parse/sintaxe dos scripts;
  - consistencia de arquivos auxiliares (`removePackage.txt`, `autounattend.xml`, README);
  - comportamento em respostas de input invalidas.

## 9) Conclusao

A auditoria permanece favoravel para merge seletivo e controlado, com foco em robustez e compatibilidade. O gargalo nao e seguranca maliciosa, e controle de regressao em PRs grandes/antigas. A estrategia correta continua sendo curadoria por blocos com testes direcionados, especialmente para #444 e #475.
