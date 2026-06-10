# redis-cache: a tiny stdlib HTTP app + the redis-py client.
FROM python:3.12-slim
RUN pip install --no-cache-dir redis
WORKDIR /app
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
