# Proveniência das mensagens Body V0

SpatialBodyV0.jsonl foi gerado do firmware enviado em TARS_FIRMWARE_AUDITORIA.zip, com o patch de emissão de encoders aplicado, usando src/main.cpp e os periféricos de tests/virtual do próprio repositório. ArduinoJson 6.21.6, host Linux 64 bits, TARS_SERIAL_BAUD=115200. Sequência: setup (status SAFE_LOCKED), CLEAR_FAULT/PING/ARM (ACKs não incluídos no arquivo), STATUS (ARMED), GET_CAPABILITIES e GET_ENCODERS. Todas as saídas de motores verificadas em zero no host.

O evento encoders no host de 64 bits omitiu counts.rr pelo orçamento StaticJsonDocument<512>; foi separado em SpatialBodyV0TruncatedHostEncoders.json e é fixture NEGATIVA. Este evento negativo foi capturado ANTES da correção. Não completamos seus campos e não afirmamos que o ESP32 de 32 bits tenha o mesmo problema.

Após a correção, os quatro eventos completos (dois status, capabilities e encoders) são a fixture POSITIVA. Nenhum evento representa estado do hardware real. Testes também constroem um evento de encoders completo em memória para verificar o contrato esperado.

Não há credenciais, memória pessoal, imagem ou áudio nesses arquivos.
