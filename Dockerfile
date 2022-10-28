FROM alpine:3.16

RUN apk update
RUN apk add --no-cache curl bind-tools jq bash

WORKDIR /hetzner-api-dyndns

COPY dyndns.sh .

CMD ["bash",  "dyndns.sh"]
