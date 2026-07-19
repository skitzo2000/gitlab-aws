FROM alpine:3.20

LABEL org.opencontainers.image.title="Spaceballs-the-docker" \
      org.opencontainers.image.description="Merchandising! Where the real money from the movie is made."

COPY ludicrous-speed.sh /usr/local/bin/ludicrous-speed
RUN chmod +x /usr/local/bin/ludicrous-speed

CMD ["ludicrous-speed"]
