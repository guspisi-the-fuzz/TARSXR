# Aceitação física — executar depois da validação de software

Este documento é um roteiro pendente, não um relato de sucesso. Não iniciar o bloco 4 a partir de resultados simulados.

1. Conversa: repetir a aceitação semântica do bloco 2 com os fatos reais existentes, sem substituir a memória pessoal. Identidade, pronomes, relações e informações ausentes devem formar respostas coerentes. Despertar, transcrição e interrupção acústica ainda exigem observação real.
2. Música: pedir uma faixa. “Carregando” não pode aparecer como reprodução confirmada. Depois da confirmação do player, perguntar pelo status do pedido. Conferir separadamente o som real no iPhone/JBL; o recibo do player não prova saída audível.
3. Pausa/retomada/encerramento: verificar que cada recibo corresponde ao estado real do player e que a conversa volta após encerrar. A transição da sessão de áudio não pode cancelar o próprio carregamento solicitado.
4. Cancelamento: durante um carregamento, usar Ouvir ou “TARS cancela o pedido”, quando o reconhecimento local estiver disponível. Uma conclusão tardia não pode falar de novo, confirmar outro pedido ou iniciar uma nova tentativa. Cancelar a espera de algo já reproduzindo não substitui o comando de encerrar música.
5. Informação pendente: pedir música sem título; o TARS pede título/artista. Encerrar normalmente a fala mantém essa pergunta; cancelar o pedido explicitamente fecha a espera pelo título.
6. Abertura externa explícita: conferir a aceitação do iOS, fallback quando aplicável e retorno ao TARS. O status não pode prometer login, conteúdo carregado ou reprodução dentro de outro app. Aguardar o callback não pode disparar outra abertura depois de um cancelamento anterior ao fallback.
7. Yahoo: usar apenas a conta já configurada e uma consulta de leitura. Verificar consulta concluída versus configuração necessária, sem marcar mensagens como lidas. Cancelar uma consulta pendente não pode gerar resposta antiga sobre outra solicitação. Nenhuma mensagem deve ser enviada.
8. Foto/selfie: conferir uma única captura e uma única confirmação de gravação. Cancelamento/erro não pode anunciar gravação confirmada. Um arquivo já criado antes da interrupção pode permanecer; não anunciar que foi apagado.
9. Background/retorno: verificar preservação da conclusão de uma abertura externa já solicitada, pausa da escuta e retorno ao app. Encerrar o processo elimina o histórico de pedidos da sessão; o app não deve inventar conclusão no próximo início.
10. Observar consumo e thermal no XR. Estes testes não medem autonomia; não elevar frequência de câmera nem alterar proteções térmicas para concluir a aceitação.

Não há teste de locomoção, ESP32, GPIO ou mecanismos de segurança neste bloco.
