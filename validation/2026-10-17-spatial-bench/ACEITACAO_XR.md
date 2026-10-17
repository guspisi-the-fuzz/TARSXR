# Aceitação espacial no XR — ainda não executada

Não acionar rodas/pescoço com este pacote. Manipular o aparelho manualmente na bancada.

## Software antes do aparelho

- Validação completa no Mac: standalone, Debug/Release e ciclo simulado. Confirmar que 180 verificações espaciais e inventário Python passam. O ciclo espacial não simula precisão de ARKit.
- Regressão de foto/selfie, visão local e voz: novos tipos são incluídos automaticamente pelo grupo sincronizado MyApp do projeto Xcode.

## Experimentos físicos e registro

1. Permissão negada: indisponibilidade clara e liberação do modo; liberar permissão e repetir.
2. Exclusão: visão local ativa impede iniciar bancada; bancada ativa impede fotografia e ativação da visão local. Parar libera a câmera. Repetir alternância cinco vezes; verificar também foto/selfie após bancada.
3. Novo mapa: acompanhar transição inicializando → tracking. Registrar versão iOS, iluminação e tempo de inicialização.
4. Deslocar manualmente 1 m medido em linha reta, retornar ao início e girar sem transladar intencionalmente. Comparar posição/trilha estimadas; registrar erro observado. Não declarar precisão ou adequação à navegação antes de analisar os resultados.
5. Marcar Sala, Corredor e Cozinha (ou três pontos de bancada); declarar Sala–Corredor e Corredor–Cozinha. Junto a Sala, simular Cozinha; verificar ordem e distância geométrica, sem movimento. Sem conexão, nenhum percurso deve ser criado. Distante dos pontos de partida, pedir relocalização/proximidade.
6. Parede lisa, pouca luz e movimento excessivo: limited/lost conforme ARKit; nenhuma rota utilizável quando tracking não estiver disponível. Encobrir a lente pode não interromper imediatamente a estimativa inercial; registrar o atraso, sem supor detecção instantânea.
7. Salvar mapa; parar/carregar na mesma área e depois em outra área. Antes da relocalização, não habilitar coordenadas/rota. Verificar reconhecimento da referência salva em condições alteradas. Não presumir que normal significa precisão física comprovada.
8. Sair do app, bloquear tela, reabrir: não reutilizar pose antiga ou reiniciar silenciosamente. Carregar/relocalizar explicitamente.
9. Voz e bancada simultâneas por 10 minutos, registrando bateria inicial/final, térmico, pausas e latência da conversa. Fazer comparação com visão econômica usando condições similares. Não contornar bloqueio serious/critical.
10. Compartilhar diagnóstico conscientemente: contém nomes de lugares, coordenadas e trilha, sem fotos/áudio/chaves. Corpo deve permanecer indisponível.

Falhas de relocalização, drift, pressão térmica ou concorrência de câmera reabrem o incremento. Não comprar componentes nem mudar hardware a partir desses resultados sem revisão.

## Ainda fora da aceitação deste pacote

Detector/identificação de pessoas ou Mel; reconhecimento semântico automático de cômodos; grade de ocupação e detecção de escadas/cabos; localização completa do chassi; firmware/transporte físico; dirigir à cozinha; localizar o usuário para “vem cá”; movimentar pescoço ou rodas.


## Cálculo das quatro rodas e importação

- Painel de cálculo: inserir geometria e limites de ensaio explicitamente escolhidos, não atribuí-los automaticamente ao robô. Avanço reto deve gerar direção zero em quatro rodas; recuo deve inverter velocidades; curva deve diferenciar velocidades internas/externas e direção dianteira/traseira. Limites inviáveis devem recusar o cálculo. Não aplicar os números a servos/motores.
- Importar Tests/Fixtures/SpatialBodyV0.jsonl: são mensagens de firmware real rodando com I/O simulado, não amostra física. ARMED com motion_allowed=true deve continuar histórico, tração indisponível e sem autoridade de atuação.
- Importar SpatialBodyV0TruncatedHostEncoders.json: recusar o campo ausente, sem inventar rr=0.
