# Bloco 1 — recuperação de memória e evidências

Base: incremento fb0bce4, já aplicado e validado no Mac pelo usuário. Este pacote deve ser aplicado sobre esses arquivos; não depende do nome/hash do checkpoint feito no Mac.

## Problemas tratados

1. O interpretador lógico devolvia apenas uma string. O controlador da memória não recebia os identificadores dos registros que sustentaram a resposta.
2. A referência usada para “ela/ele” dependia de haver exatamente uma chave de fato. Vários fatos sobre uma pessoa não equivalem a várias pessoas.
3. A seleção limitada a quatro registros podia priorizar chaves de um assunto anterior e omitir o sujeito explicitamente nomeado na pergunta atual.
4. A referência em RAM precisava acompanhar o proprietário e a revisão do arquivo, inclusive quando uma exclusão ocorre fora do runtime.

## Contrato implementado

- `XRMemoryReasoner.resolve` retorna resposta, IDs das fontes utilizadas no resultado, proprietário e revisão. `answer` continua disponível por compatibilidade.
- O runtime nativo usa o contrato estruturado. Rejeita fontes inexistentes e identidades/revisões divergentes; verifica cancelamento e alteração durante a consulta.
- O assunto nomeado da consulta é separado dos IDs de evidência. Um nome inequívoco pode permanecer como referência por até 120 segundos; dois nomes pedem esclarecimento. Mudanças do arquivo, troca de assunto por ferramenta e conversa geral invalidam o foco.
- Recuperação prioriza o sujeito explicitamente citado, mantém o limite de quatro fatos e expõe contagens de correspondências e omissões no contexto local.
- Nenhuma resposta do interpretador é gravada como fato. As operações explícitas existentes de salvar, corrigir e esquecer permanecem responsáveis pelas escritas.
- Não há mudança de schema, migração, limpeza de registros pessoais ou troca de credenciais.

## Limites e próximos blocos

Este incremento não altera o formatador “Pelos fatos registrados” e não resolve transcrição, despertar ou interrupção acústica. Português natural e raciocínio conversacional pertencem ao bloco 2. Não adiciona chamadas de API: a interpretação existente continua usando a mesma configuração quando necessária.

Os IDs de origem permitem rastrear a evidência; não provam que a extração semântica do modelo esteja correta. A validação existente de termos literais e execução relacional permanece. Nomes arbitrários são usados nos testes, sem regras especiais para Mel ou Daniela.

## Validação

Os testes usam arquivos temporários, relógio injetado e interpretadores simulados. Cobrem múltiplas fontes para um sujeito, referência expirada, ambiguidade, mudança de ferramenta, exclusão externa, identidade/revisão inválida, fonte inventada, prioridade de recuperação e preservação dos bytes do arquivo pessoal simulado.

O instalador executa a validação completa do Mac (checks, Debug/Release e ciclo de aplicativo simulado). Não instala no XR nem faz commit/push. O Mac do usuário é necessário para os builds Apple; o ambiente de desenvolvimento deste pacote é Linux.

Aceitação física permanece pendente. Para não misturar blocos, não usar a persistência do estilo telegráfico como prova de falha desta correção de evidências: o estilo será tratado no bloco 2. Também não considerar testes simulados como prova de uma conversa real funcionando.

Resultado local: suíte portátil completa aprovada, incluindo 89 verificações de continuidade/evidência, 218 de memória persistente, 384 de relações e 228 de intenção falada. O diálogo integrado também passou com o contrato estruturado usado em produção; o adaptador antigo permanece coberto pela execução portátil anterior. Ver `PORTABLE_RESULTS.txt`. Builds Apple não foram executados aqui.
