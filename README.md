# Acompanhamento de Saldos e Conciliação Contábil

Sistema web para substituir a planilha do Google Sheets usada no acompanhamento mensal de contas correntes,
aplicações, caixas, fornecedores e clientes de várias empresas.

- **Front-end:** um único arquivo `index.html` (HTML + CSS + JavaScript puro), hospedável no GitHub Pages.
- **Banco, login e permissões:** Supabase (PostgreSQL + Auth + RLS).
- **Bibliotecas externas (carregadas sob demanda):** supabase-js e fonte Inter (sempre); SheetJS, jsPDF e jsPDF-AutoTable (só ao importar/exportar XLSX ou PDF), via CDN jsDelivr.

## Estrutura do repositório

```
index.html                              aplicação completa
README.md                               este documento
supabase/
  001_fundacao.sql                      tabelas, restrições, RLS, auditoria, travas
  001_reset_e_criar.sql                 igual ao 001, mas apaga tudo antes (só com banco vazio!)
  002_contas_verbo_da_vida.sql          carga das contas da empresa (exemplo de uso)
  003_criar_competencia.sql             função create_period (abre competência copiando as contas ativas)
  003_competencia_setembro_2026.sql     carga de setembro/2026 da empresa original (exemplo)
  004_encerramento.sql                  encerrar e reabrir competência
  005_divergencias_auditoria.sql        proteção das divergências e auditoria completa
  006_importacao.sql                    importação atômica de planilhas
  007_testes_banco.sql                  testes automáticos (desfazem os próprios dados)
```

## Configuração do banco (uma vez)

No Supabase (SQL Editor), rode **nesta ordem**, cada arquivo inteiro e uma única vez:
`001_fundacao.sql` (ou `001_reset_e_criar.sql` em banco vazio) → `003_criar_competencia.sql` → `004` → `005` → `006`.
Os arquivos `002_contas_verbo_da_vida.sql` e `003_competencia_setembro_2026.sql` são **cargas de dados da empresa original**
(exemplo) e não devem ser usados para outras empresas: use as telas e a importação.
Depois rode o `007_testes_banco.sql` para conferir as regras do banco.

**Primeiro usuário:** crie-o em *Authentication > Users > Add user* (e-mail e senha, com e-mail confirmado)
**depois** de rodar o SQL. O primeiro usuário criado vira administrador; os seguintes entram como operador.
Novas pessoas: criar o login no Supabase e depois definir perfil e empresas na tela *Usuários e responsáveis*.

## Configuração do front-end (variáveis)

No início do `index.html`:

| Constante | Onde obter | Observação |
|---|---|---|
| `SUPABASE_URL` | Project Settings > API | endereço do projeto |
| `SUPABASE_ANON_KEY` | Project Settings > API Keys | chave **publishable** (`sb_publishable_...`) ou `anon` |

A chave publishable é pública por desenho: quem protege os dados são as políticas RLS. **Nunca** coloque a chave
`secret`/`service_role` no arquivo nem no repositório.

## Executar localmente

Dê dois cliques no `index.html`, ou sirva a pasta: `python3 -m http.server 8000` e abra `http://localhost:8000`.

## Implantação (GitHub Pages)

1. Crie um repositório no GitHub e envie `index.html`, `README.md` e a pasta `supabase/`.
2. *Settings > Pages > Build and deployment*: Source = *Deploy from a branch*, branch `main`, pasta `/ (root)`.
3. Aguarde alguns minutos e abra o endereço `https://SEU-USUARIO.github.io/NOME-DO-REPOSITORIO/`.
4. No Supabase: *Authentication > URL Configuration*, coloque esse endereço em *Site URL*.
5. Entre com o administrador e confira *Configurações* (diagnóstico todo "OK").

O repositório pode ser público: ele contém apenas o código e a chave publishable. Os dados ficam no Supabase, protegidos por login e RLS.

## Perfis e permissões (aplicadas no banco)

| Perfil | Pode |
|---|---|
| Administrador | tudo: usuários, empresas, categorias, contas, competências, encerrar (mesmo com pendências), reabrir, auditoria |
| Contador / supervisor | ver empresas vinculadas, abrir competências, importar, editar registros, registrar divergências, ver relatórios e auditoria; encerrar só onde marcado "Pode encerrar" e sem pendências |
| Operador | ver empresas vinculadas, informar saldos, situações, responsáveis, observações e divergências |

Ninguém altera o próprio perfil. Dados de uma empresa só aparecem para quem foi vinculado a ela.

## Regras de cálculo

- Valores em `NUMERIC(15,2)`; somas em centavos inteiros no navegador (sem erro de ponto flutuante).
- Saldo vazio (`NULL`) = "não informado"; é diferente de R$ 0,00. Totais com itens sem saldo são marcados como **parciais**.
- **Disponibilidade financeira** = saldo final dos registros de categorias marcadas como "entra na disponibilidade" (bancos, aplicações, caixas), excluindo itens "Não aplicável". Fornecedores e clientes nunca entram.
- **% de conclusão** = concluídos ÷ itens aplicáveis (itens "Não aplicável" não entram no denominador). Preencher saldo não conclui a conciliação: a situação é independente.
- Sempre uma competência por vez; competências diferentes nunca são somadas.
- Nova competência: copia as contas ativas; saldo final vazio, situação Pendente, saldo anterior = saldo final do mês anterior.

## Testes

**Automáticos (banco):** `supabase/007_testes_banco.sql` verifica CNPJ, texto de contas, vazio x zero, duplicidades, auditoria, divergências, bloqueio de competência encerrada, proteção da situação da competência, RLS ligada e ausência de acesso anônimo. Rode após qualquer mudança no banco. Não substitui os testes manuais abaixo, porque o SQL Editor roda como administrador do banco e não simula usuários diferentes.

**Manuais (repita em produção, com dois usuários de teste):**
1. Operador sem vínculo não vê nenhuma empresa; com vínculo a A, vê só A (abra a tela em janela anônima).
2. Operador não consegue promover a si mesmo (a tela não oferece; no console, `update profiles set role='admin'` deve falhar).
3. Operador não vê o histórico de auditoria nem consegue encerrar competência.
4. Supervisor sem "Pode encerrar" é recusado; com a marcação, encerra só sem pendências.
5. Competência encerrada: campos bloqueados; reabrir exige administrador e justificativa.
6. Importação: arquivo com linha inválida rejeita só aquela linha; registros existentes só mudam se "Sobrescrever" for escolhido.
7. Exportações CSV, Excel e PDF abrem com acentos, números de conta como texto e totais corretos.
8. Recarregar a página mantém os dados.

## Limitações e dependências externas

- Criação de logins é feita no painel do Supabase (o navegador não pode usar chave administrativa).
- Exportações em Excel/PDF e leitura de XLSX precisam de internet para baixar as bibliotecas na hora.
- Plano gratuito do Supabase pausa projetos inativos por semanas; faça backups periódicos (Database > Backups ou exportação das tabelas).
- Em XLSX, zeros à esquerda já removidos pelo Excel em células numéricas não são recuperáveis; prefira CSV.
