# Bloco 2 — conversa natural sobre a memória

Base do incremento: 77214bb (arquivos do bloco 1 já aplicados e aprovados no Mac). O hash do checkpoint no Mac pode ser diferente; a aplicação confere o conteúdo dos arquivos.

## Mudança de arquitetura

No caminho nativo configurado, uma consulta pessoal de leitura elegível deixa de terminar no parser local ou no formatador de linhas do avaliador lógico. `MemoryTARSRuntime` reúne a pergunta, os últimos oito turnos e até 24 fatos relacionados e chama `NativeAIService.converseMemory` uma única vez. O mesmo modelo já configurado no XR recebe a tarefa de compreender a pergunta e construir a resposta completa. Não há troca de credenciais, fornecedor ou voz.

A seleção inclui correspondências explícitas, o assunto recente válido e até duas expansões por menções entre registros. É uma recuperação textual limitada; não é um grafo semântico completo. Relações reconhecidas pelo parser, como “meus irmãos”, também fornecem chaves de busca. Quando uma pergunta pessoal ampla não possui correspondência literal, recebe um recorte limitado da memória em vez de um conjunto falsamente vazio. Registros explicitamente nomeados têm prioridade. Omissões são informadas e a seleção não pode ser tratada como uma lista exaustiva de pessoas ou relações.

O retorno estruturado contém `status`, `speech`, `source_keys` e `focus_key`. O aplicativo verifica formato, limites, fontes existentes, foco conhecido, cancelamento e revisão do arquivo. A resposta natural entra uma única vez no contexto compartilhado e segue intacta para a voz. Uma pergunta de esclarecimento aceita uma resposta curta por até 120 segundos, vinculada ao proprietário e à revisão; perguntas novas mantêm seu roteamento. O foco devolvido permite continuar sobre outra pessoa apresentada na resposta, em vez de insistir no nome da pergunta anterior.

O novo caminho faz o raciocínio linguístico no modelo; não executa uma consulta `XRLogic` adicional para certificar cada inferência. O avaliador relacional permanece disponível nos caminhos anteriores e seus testes continuam rodando. As fontes retornadas não equivalem a uma prova formal do conteúdo da fala.

A conversa geral continua com suas ferramentas e rotas existentes, mas recebe orientação explícita para responder em frases naturais. Ela e as consultas de memória recebem o mesmo histórico gerenciado pelo runtime, sem outro histórico privado no novo endpoint de memória.

## Limites de autoridade

Salvar, corrigir, esquecer e confirmações continuam exclusivamente nos caminhos locais existentes. Consultas específicas de nome dos pais e a seleção A/B já implementada permanecem determinísticas. Comandos e confirmações não são convertidos em interpretação probabilística.

O novo endpoint não oferece ferramentas, web, movimentos, segurança, câmera nem escritas. Sua fala não pode executar nada. Respostas de câmera e email são contexto histórico não confiável, não autorização nem fonte para inventar fatos pessoais persistentes. O estado real da câmera e a captura não mudam neste bloco.

## Custo, latência e falhas

Consultas pessoais que antes eram respondidas gratuitamente pelo parser agora podem fazer uma chamada paga. Usa o modelo configurado, esforço de raciocínio `medium`, saída limitada a 1800 tokens, até 24 fatos e entrada JSON de até 100 KB. Não faz uma chamada lógica seguida de outra para embelezar a fala. Não há repetição automática nem fallback pago em caso de erro; cota, cancelamento ou resposta inválida não produzem uma segunda consulta oculta.

Isso melhora a informação disponível para formular a resposta, mas não é uma promessa de latência menor. A captura/transcrição e a reprodução de voz existentes não foram substituídas por áudio full duplex.

## O que os testes demonstram

`MemoryConversationChecks` usa interpretador simulado e arquivos temporários. Verifica encaminhamento correto, preservação da resposta completa, fatos relacionados, foco e histórico entre turnos, expiração, separação de conversa pública/visual, ausência de escritas, rejeição de fontes inventadas e campos de ação, sobreposição, cancelamento, mudança de revisão e falha sem segunda tentativa.

`NativeAIChecks` verifica pelo URLProtocol a requisição real construída: schema estrito, contexto, raciocínio configurado, nenhuma ferramenta, uma chamada e rejeição de fontes inexistentes. Esses testes Apple dependem do Mac e são executados pelo instalador.

**Respostas simuladas bem escritas não demonstram que o modelo real respondeu bem.** IDs válidos demonstram rastreabilidade, não provam que todas as afirmações da fala estão semanticamente sustentadas. Não foi feita uma avaliação paga do modelo real neste ambiente. Os cenários em `ACEITACAO.md` ainda exigem respostas reais, com os fatos correspondentes registrados, antes de declarar o bloco aceito como conversa. Nenhum dado pessoal foi copiado ou corrigido pelos testes.

Consultas de duração pessoal (“há quanto tempo Iara mora comigo?”) podem usar esse contexto sem serem confundidas com a palavra “tempo” de uma pergunta meteorológica. Uma pergunta explícita sobre chuva preserva a rota de serviço existente. Esse filtro não pretende ser um classificador universal de intenções.

## Resultado local e limite do ambiente

O novo caminho passou em 39 verificações determinísticas. Os demais checks portáteis também passaram por etapas, incluindo 89 de continuidade, 307 de lógica, 218 de persistência, 228 de intenção falada e 384 de relações. O método real de construção/decodificação da requisição foi compilado em um scaffold com transporte simulado.

Duas execuções foram interrompidas por SIGILL do runtime Swift neste Linux, com referência a `/proc/.../stat`, sem asserção de teste identificada. O teste de continuidade passou ao repetir o mesmo binário; persistência passou com afinidade em uma CPU. Os checks restantes também foram executados nessa configuração. Nenhuma asserção foi removida e o runner não foi alterado para ignorar falhas. Não se declara uma rodada integral única aprovada no Linux padrão. Ver `PORTABLE_RESULTS.txt`.

Builds Apple, URLProtocol e ciclo Simulator do incremento final aguardam execução no Mac. O pacote não instala no XR e não faz commit/push. A aceitação semântica com modelo real continua separada e pendente.
