# Bloco 3 — pedidos locais, confirmação e cancelamento

Base: dcc3355, arquivos do bloco 2 com a correção do teste de corpo HTTP, já aprovados no Mac. O hash do commit do usuário pode diferir; a aplicação verifica os arquivos, não exige esse nome de commit.

## Problemas observados no código

- Abertura de aplicativos retornava uma fala e criava uma Task independente com atraso. O pedido podia ser interrompido e a abertura ocorrer depois; o resultado de `UIApplication.open` não era usado para formular o retorno.
- Reprodução e pausa confirmadas pelo YouTube retornavam uma string vazia para não falar sobre a música. O contexto não recebia uma confirmação útil.
- Não havia um ciclo comum para distinguir pedido recebido, execução, confirmação, falta de confirmação, indisponibilidade e espera interrompida.
- Callbacks do player eram identificados apenas pelo vídeo; duas solicitações do mesmo vídeo podiam compartilhar essa identificação.

## Implementação

`LocalActionCoordinator` aceita um pedido por vez e associa seus eventos a um UUID. O resultado vem de adaptadores locais tipados (`LocalActionResult`), nunca de uma resposta do LLM. Sucesso exige uma confirmação informada pelo adaptador. O UUID impede que a conclusão de um pedido cancelado substitua o estado de outro pedido. Não há repetição automática de operações com falha.

O HUD mostra a categoria e o estado do pedido. O resultado terminal entra uma única vez no contexto compartilhado, com identificador do pedido, estado, confirmação e observação. Reprodução silenciosa também produz esse registro. Esses dados continuam sendo relatórios históricos citados, sem autoridade de execução.

| Adaptador | Confirmação usada | Limite do que se pode afirmar |
| --- | --- | --- |
| Yahoo | Resposta IMAP de busca/leitura ou retorno local da exclusão de credencial | Consulta concluída ou credencial local removida; nenhum envio de email foi adicionado. BODY.PEEK preservado. |
| Música | Estado/posição reportados pelo player da página atual | O player confirmou reprodução/pausa/início. Não prova som audível no JBL. Timeout permanece sem confirmação. |
| Foto/selfie | Retorno das gravações já existentes no cache e na biblioteca | Confirma gravação após os dois retornos; falha/cancelamento não garantem apagar um arquivo já criado. |
| Abertura externa | Callback de aceitação do iOS, inclusive alternativa | Confirma aceitação da URL. Não confirma carregamento, login ou reprodução dentro de outro aplicativo. |

Cada página do player possui um token independente do ID do vídeo; mensagens de uma página anterior são descartadas, mesmo para o mesmo vídeo.

## Cancelamento e transições do sistema

Ouvir/TARS escuta e o pedido explícito “TARS cancela o pedido” interrompem a espera ativa. A consulta Yahoo pendente é fechada; carregamento musical ainda pendente é descartado. Reprodução já estabelecida não é desfeita por cancelar a espera; o comando de encerrar música permanece disponível como antes.

O cancelamento explícito também pode fechar a etapa “qual música?”. O término normal da fala não cancela essa pergunta pendente. A evidência de cancelamento diz que a espera foi interrompida e não promete desfazer efeitos já ocorridos. Uma abertura já aceita pelo sistema ou uma gravação já efetuada não pode ser considerada revertida.

A interrupção de áudio durante uma transição de mídia não deve matar o pedido que aguarda a confirmação do próprio player. O proprietário desse pedido é preservado nessa transição, enquanto a captura/fala segue o tratamento existente. Uma abertura externa explícita também pode aguardar o callback do iOS ao ir para background. Isso não permite novas operações autônomas em background: somente aguarda o resultado do pedido já iniciado. Cancelamento explícito continua cancelando a espera.

Consultas explícitas “qual o status do pedido?”, “como está o pedido?” e “já terminou?” leem o último recibo da sessão sem chamar IA, executar novamente ou alterar o estado do pedido. Uma resposta sobre o último pedido não é uma leitura atual de todos os aplicativos.

## Escopo preservado

- ESP32, motores, GPIO, recuperação, segurança e autoridade de movimento não foram alterados.
- Nenhuma nova operação de envio de mensagem, email ou escrita de memória pelo modelo foi criada.
- As operações explícitas de salvar/corrigir/esquecer memória mantêm sua própria verificação local existente.
- A visão sequencial mantém seu pipeline, frequência, filtro, orçamento e estados. Análise visual continua com seus estados anteriores; este incremento rastreia a gravação de foto/selfie, sem transformá-la em sensor de navegação.
- Não há migração de dados, alteração de Keychain por instalador, nova voz, alteração de volume ou mudança das categorias de áudio configuradas. Há integração do cancelamento e do proprietário de execução com o ciclo de áudio existente.
- Os recibos são de sessão, em RAM. O histórico compartilhado continua limitado a oito turnos e cinco minutos. Reiniciar o app não restaura pedidos nem prova o resultado de uma operação interrompida.
- O coordenador não acrescenta chamadas de IA nem repetição paga. As consultas de memória do bloco 2 e os serviços já existentes mantêm seus custos.

## Verificações e limites

Os testes novos exercitam estados, confirmação silenciosa, rejeição de sucesso sem evidência, duplicação, concorrência, cancelamento, conclusão tardia, consulta de status, abertura alternativa e fronteiras dos comandos. Os métodos reais do modelo/HUD e do player foram ainda extraídos para scaffolds de transporte/UI simulados para verificar tipo e encaminhamento. Isso não equivale a compilar WebKit/UIKit.

O ciclo do aplicativo no Simulator passa a exercitar o player real com fixtures locais, sem busca/reprodução online, e o controlador real de áudio com captura/saída simuladas. Verifica encerramento, recibos, cancelamento de carregamento, preservação de reprodução estabelecida, hook de cancelamento e preservação do proprietário durante handoff. Esses testes Apple exigem o Mac.

O ambiente Linux apresentou uma interrupção SIGILL do runtime em memory-conversation, sem asserção identificada, com referência a /proc/.../stat. O mesmo binário passou separadamente; as demais verificações portáteis foram executadas por etapas. Não há declaração de rodada integral única aprovada no Linux padrão. Os resultados estão em PORTABLE_RESULTS.txt; nenhuma asserção foi removida para contornar a falha.

O instalador faz backup, aplica o incremento e executa a validação completa do Mac (checks, Debug/Release e ciclo Simulator). Não instala no XR e não faz commit/push. Builds Apple e aceitação física do incremento final ainda estão pendentes neste pacote.
