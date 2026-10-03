# postgres-app: a tiny stdlib HTTP app + the psycopg Postgres driver.
FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]"
WORKDIR /app
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
