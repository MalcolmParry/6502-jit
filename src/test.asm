* = $0600
lda #$05
clc
adc #$03
sta $0200
.byte $02 ; hlt
