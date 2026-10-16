# TARSXR — etapas 1, 2 e 3

Base: `ffee6cdd17730bec4c1eb593b1498ebed253b674`, branch publicada `feature/xr-bench-mode`.

1. **Conversa e continuidade de raciocínio** — incremento de software deste pacote. Aceitação no Mac e no XR ainda necessária.
2. **Percepção espacial em bancada** — próxima etapa, sem iniciar neste pacote. Exigirá medidas e incerteza verificáveis, além de descrições.
3. **Navegação integrada** — posterior à bancada, sujeita às proteções existentes. Nenhuma autoridade de movimento foi adicionada.

## O que muda na etapa 1

- Registro temporário comum: até oito turnos completos, por até cinco minutos, somente em RAM. Cada turno inclui pergunta, resultado, origem e idade. Imagens são observações históricas; não comprovam ambiente atual nem espaço livre.
- Respostas determinísticas de memória e resultados locais de câmera, email, música e abertura de aplicativos chegam à conversa geral. Nenhum registro de diálogo vira fato persistente automaticamente.
- Revisão dos dados persistentes separada da geração que invalida uma requisição. Leituras locais não apagam a continuidade na chamada seguinte. Correções/exclusões/mudança de proprietário limpam os turnos anteriores; o controle de respostas que chegam atrasadas continua existindo.
- Uma conversa por vez. Cancelamentos não publicam respostas nem as adicionam ao contexto. Resultados visuais passam por um único ponto de registro para voz e botão.
- Perguntas públicas sem vínculo com fatos locais deixam de pagar a interpretação lógica de memória primeiro. Referências após uma ferramenta não retomam indevidamente o tópico de memória anterior.
- “Essa informação está salva?” exige um referente recente ainda presente no banco. Ter qualquer fato salvo não basta. Ambiguidade permanece motivo para pedir esclarecimento.
- Falha da memória não bloqueia uma pergunta independente de conhecimento geral; perguntas pessoais continuam recusadas quando os dados não podem ser lidos.
- Pausa de fim de fala passa de 2,2 para 1,2 segundos. Novos resultados parciais de reconhecimento mantêm a fala aberta. O limite máximo de captura e as permissões continuam.
- Retomada normal da escuta passa de 600 para 150 ms; erros mantêm o backoff anterior. A mensagem errada de “30 segundos” foi removida: o estado acordado já persistia até “dorme”.
- Respostas longas podem começar com uma frase pronta enquanto o restante é sintetizado. Até duas partes, na ordem, sem repetir o prefixo. Cada áudio completo continua validado e reproduzido por AVAudioPlayer, com a mesma voz Onyx e instruções. O streaming PCM que falhou no XR permanece desativado.
- Interrupção local com “TARS escuta”, “TARS pare de falar” ou “TARS listen” quando reconhecimento local, autorização e rota estão disponíveis. A frase abre um novo turno; não executa ferramentas ou movimento. Botão “Interromper e ouvir” como alternativa. O monitor é limitado a 60 segundos e para ao suspender a sessão. Não há garantia de cancelamento acústico de eco.
- Reconhecimento online multilíngue explicitamente configurado continua sendo respeitado. `TARS_PREFER_LOCAL_STT=1` permite experimentar reconhecimento incremental local após acordar, se já autorizado/disponível. O reconhecedor local usa o locale configurado; não é substituto comprovado para fala PT/EN misturada. Não há envio online automático como alternativa a uma falha local.

## Melhorias visuais plausíveis do parecer externo

A captura sequencial permanece em VGA e com os mesmos limites/cadência/temperatura. A normalização preserva agora até 640 pixels no maior lado; se o PNG não couber no contrato de 1.000.000 bytes, tenta a normalização anterior de 480. Fotografias preservam seu caminho e limite de normalização anterior.

Pedidos explícitos de ler texto/código usam `detail: high`; descrições gerais continuam em `low`. O parser reconhece mais perguntas explícitas sobre o que está vendo/enxergando, leitura da tela e procura na imagem. Perguntas históricas como “o que você viu?” seguem para o contexto de conversa, sem nova análise paga.

Isso recupera detalhe descartado pelo software, sem garantir OCR. Não aumenta a resolução do sensor nem descarta borrão óptico. O limite é do PNG antes do base64; base64 aumenta o corpo enviado. Intervalo mínimo de 30 s, cinco tentativas por execução, qualidade, idade máxima de oito segundos e mudança de cena continuam. Não há envio automático periódico à IA.

## Custos e recuperação

- Testes usam respostas sintéticas; não fazem chamadas pagas nem acessam memória pessoal.
- Contexto compartilhado substitui o histórico isolado no caminho gerenciado, evitando a duplicação dos mesmos turnos.
- Respostas curtas mantêm uma síntese. Respostas longas podem fazer duas; há uma única preparação futura em andamento. Cancelar impede a reprodução do restante, mas não garante estorno de trabalho já recebido pelo provedor.
- `high` só em leitura explícita pode elevar custo de imagem; não existe promessa de economia nem de leitura perfeita.
- `TARS_CONVERSATION_AUDIO=legacy` restaura áudio em uma parte, pausa de 2,2 s e desliga o novo monitor de interrupção. Não reverte a correção de contexto. A retomada rápida de 150 ms permanece.

## Validação disponível sem XR

`bash scripts/validate-runtime-boundary.sh` roda verificações portáveis; no Mac também compila Debug para Simulator, roda testes nativos com URLProtocol e compila Release para iOS sem assinatura.

`bash scripts/validate-conversation-simulator.sh` executa essa validação e instala **apenas no Simulator**, depois roda o ciclo simulado de câmera/áudio do próprio app. Inclui WAV silencioso com AVAudioPlayer/delegates, partes ordenadas, cancelamento, wake/follow-up, respostas atrasadas, indisponibilidade e recuperação. Não precisa de chave ou de XR conectado. Requer Xcode com um runtime iOS instalado. Pode selecionar o simulador com `TARS_SIMULATOR_ID`.

Os testes de protocolo verificam o conteúdo real dos pedidos montados pela aplicação, com provedor simulado. Eles não demonstram a qualidade semântica de um modelo real nem medem latência da internet.

## Verificação final no XR físico

Após a validação no Mac, um único build no aparelho pode concentrar estes testes:

1. Acordar, perguntar e fazer dez follow-ups sem repetir TARS. Testar pausas naturais sem cortar finais de frase.
2. Consultar um fato conhecido; mudar para pergunta geral; retomar uma referência clara e outra ambígua. A ambígua deve pedir esclarecimento.
3. Descrever imagem e perguntar “o que você viu?”. Desligar a visão e perguntar o que vê **agora**: não deve reutilizar uma descrição antiga como observação atual.
4. Testar correção e esquecimento com fatos descartáveis novos, preservando a memória real. Conferir que a conversa não revive o valor removido.
5. Durante resposta longa, usar “TARS escuta”; depois o botão. Não pode repetir o começo, tocar uma resposta cancelada ou executar comando de corpo.
6. Repetir com alto-falante do XR e JBL. Verificar eco, auto-interrupção, mudança de rota, clareza e continuidade entre partes. Este é um critério obrigatório para aceitar o áudio novo.
7. Testar PT, EN e fala misturada no modo de entrada usado no aparelho. Não habilitar o modo local experimental como substituto do multilíngue sem comparar a transcrição.
8. Pedir leitura de texto grande, com a câmera parada, e comparar com uma descrição geral. Registrar erros de leitura e condições; este teste não calibra navegação.
9. Executar 15–20 minutos, anotando bateria, temperatura, erros e tempos. Validar suspensão ao sair do app, recuperação ao voltar e bloqueios térmicos da visão.

Critério de conclusão da etapa 1: testes de software aprovados no Mac, fluxo acima aprovado no XR e checkpoint publicado. Até lá, “software implementado” não significa “conversa contínua fisicamente validada”. O pipeline ainda possui transcrição/resposta/síntese no modo online; este pacote reduz esperas e sobrepõe a preparação da voz, sem afirmar que virou uma sessão Realtime de áudio full duplex.

## Preservação

Nenhum arquivo de ESP32, GPIO, motores, geometria do corpo ou mecanismo de segurança foi alterado. `live_camera`, `actions_enabled` e geometria métrica continuam sem conferir autoridade de navegação. Os testes antigos de memória, relações, intenção de fala, qualidade e admissão visual continuam sendo critérios de regressão.
