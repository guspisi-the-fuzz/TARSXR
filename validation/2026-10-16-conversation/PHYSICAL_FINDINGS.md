# Etapa 1 — resultado físico reprovado e correção incremental

Relato do usuário em 16/10/2026, após aprovação do ciclo simulado. A etapa 1 não foi aceita no XR.

## Observações

- “TARS, wake up” recebeu uma interpretação de conversa geral sobre música/carros.
- Uma consulta sobre Mel respondeu apenas “gata”; o follow-up de residência falhou. Mais tarde, a conversa conseguiu produzir o fato completo. Isso não comprova ausência dos fatos no armazenamento.
- A consulta sobre irmãos primeiro recebeu ausência e posteriormente recebeu nomes. Não se alterou nem se corrigiu a grafia dos nomes reais.
- Uma frase com xingamento virou candidata a memória; o usuário recusou. Não há evidência de que essa candidata tenha sido salva.
- A consulta do nome do pai exibiu rótulos de aniversário/nascimento como alternativas. A resposta “B” recebeu uma confirmação genérica, sem resolver a seleção local.
- “TARS escuta” não interrompeu a saída; o usuário não encontrou o botão. Um trecho final da descrição foi repetido.
- A visão desligada recusou uma descrição atual. Ligada, gerou descrição. A previsão também respondeu; este teste não verifica a exatidão meteorológica ou todos os detalhes da imagem.

## Causas verificadas no código e limites do diagnóstico

1. O parser de ativação consumia apenas um prefixo: “TARS, wake up” podia deixar “wake up” como pergunta. Não há gravação da transcrição original para excluir um erro adicional de STT.
2. Perguntas com “eu quero saber…” não tinham a mesma rota das consultas diretas. A interpretação lógica podia anteceder uma resposta local disponível e reduzir uma identidade à categoria “gata”.
3. As opções de nome não mantinham uma seleção local. Rótulos legados de atributos podiam ser renderizados como nomes no leitor de perfil.
4. O botão ficava após o texto de resposta, sem limite de linhas. Ele foi movido para o topo, com altura preservada. A visibilidade real ainda precisa de conferência no XR.
5. O reconhecedor de interrupção exigia autorização local que uma sessão online podia não ter solicitado. A autorização local é opcional para esse recurso; sua recusa não autoriza troca silenciosa do modo online já escolhido.
6. Eco é uma hipótese para a repetição do trecho final, não uma causa comprovada. O filtro novo só rejeita uma cauda literal longa de saída própria, capturada nos quatro segundos seguintes; preserva perguntas novas, respostas curtas e repetição explicitamente endereçada a TARS.

## Correção

- Consumir prefixos de ativação consecutivos, incluindo nome + wake up, sem mandar uma saudação para conversa geral.
- Normalizar somente invólucros de perguntas. Preservar negações e manter a recusa de uma sugestão quando o usuário diz “Não” e pergunta outra coisa na mesma fala.
- Dar precedência à leitura determinística de perguntas locais. Preservar os caminhos explícitos de gravar/corrigir/esquecer.
- Responder ao follow-up de residência com fatos atualmente salvos e um referente recente único; pedir esclarecimento quando ele não existe.
- Excluir rótulos de atributos das opções de nome sem apagar registros. A/B fica vinculado a proprietário, revisão e validade de 120 segundos. A escolha vale para a consulta e não é uma correção persistente implícita.
- Não propor gravação implícita a partir da frase incidental com xingamento coberta pela reprodução.
- Mostrar “Ouvir” acima da área de resposta e indicar se a interrupção por voz está disponível. Manter a reprodução da voz aprovada e o cancelamento conjunto das tarefas.

Não se migrou o banco, não se regravaram fatos existentes e não se alteraram ESP32, GPIO, motores ou segurança.

## Validação e aceitação

O relato foi reproduzido com entidades sintéticas em arquivos temporários, incluindo nomes válidos e rótulos legados de datas. Nenhuma memória pessoal do aparelho foi acessada. A aprovação sintética não comprova acústica, foco, Bluetooth, semântica de chamadas reais ou latência de rede.

É obrigatória nova passagem pelo build e ciclo do Mac/Simulator antes de outro teste físico. Depois, repetir: despertar; identidade → residência; recusa + pergunta de irmãos; nome do pai sem datas como nomes; A/B em ambiguidade real; Ouvir; interrupção por voz quando indicada disponível; ausência de repetição da cauda. A etapa continua aberta até essa aceitação.

### Resultado disponível nesta entrega

A nova sequência passou em **78 checks portáteis**. A rodada completa anterior passou nos 218 checks de memória, 384 de relações e 228 de intenção de fala, além dos demais componentes, com 76 checks novos naquela compilação. A diferença final acrescenta duas verificações de rótulo versus sobrenome; a filtragem foi restringida para preservar um nome legítimo como “João Nascimento”. O ciclo do app inclui agora a saudação composta e o bloqueio de cauda de eco, mas ainda precisa ser executado no Mac.

O log Linux voltou a apresentar um fragmento de sinal do runtime após resultados PASS, embora o runner tenha retornado zero. A ocorrência não é tratada como validação Apple e permanece registrada no arquivo de resultados. A compilação com SDK e o ciclo no Mac continuam sendo uma passagem obrigatória, sem instalar no XR.
