# Aceitação física deste incremento

Somente após o instalador concluir todos os checks no Mac, abrir a cópia correta do projeto no Xcode, selecionar o XR físico e executar Run. Confirmar que não há outra cópia sendo instalada por outra janela. Este documento é um roteiro, não resultado executado.

1. Com térmica nominal/fair, sem música e com visão sequencial desligada, abrir bancada e iniciar Novo mapa. Registrar tempo até TRACKING ou motivo do timeout; não aguardar RELOCALIZING indefinidamente. O prazo de mapa novo é 25 s.
2. Em TRACKING, digitar um nome em 4B enquanto move a câmera devagar. Verificar resposta do teclado/botão, permanência da confirmação do cadastro e atualização do trajeto. Comparar último/pico de entrega mostrados; exportar diagnóstico se houver lentidão. Não existe ainda um limite validado de latência de toque no XR.
3. Parar, iniciar outro mapa e repetir três vezes. Verificar pose limpa, nova referência e nenhuma posição ao vivo após parar. Lugares anteriores podem continuar históricos ao parar; Novo mapa cria outra referência.
4. Salvar um mapa com dois lugares, parar e carregar na mesma área. Só aceitar lugares atuais após relocalização confirmada. Se não reconhecer a referência em 45 s, deve encerrar com erro e manter o arquivo salvo. Não assumir alinhamento só porque o desenho está visível.
5. Repetir em alimentação contínua, condição final esperada do robô, registrando duração e estados térmicos. SERIOUS/CRITICAL continuam bloqueando; este incremento não demonstra autonomia térmica nem elimina aquecimento do ARKit/carga.
6. Depois de validar digitação, repetir uma conversa curta durante o tracking. A conversa deve manter os fatos e o mapa deve continuar fresco. Não narrar comandos de teste para o microfone esperando que sejam comandos de mapa: controles espaciais continuam manuais nesta bancada.
7. Em teste separado, tocar/parar uma música para verificar que a criação sob demanda não quebrou a reprodução. Seleção da faixa correta continua uma pendência anterior do bloco 3.

Falha ou lentidão deve ser registrada com tempo, estado, condição de alimentação, térmica e diagnóstico. Este teste não autoriza roda/pescoço nem comprova obstáculo, piso ou distância física percorrida.
