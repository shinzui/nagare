# uploads-volume example image (EP-37): a tiny stdlib Python HTTP server that
# stores uploads on the durable /uploads volume. No third-party deps.
FROM python:3.12-alpine
WORKDIR /app
COPY app.py ./
EXPOSE 8080
CMD ["python3", "app.py"]
