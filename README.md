# Fizz
<img width="1508" height="785" alt="example_workflow" src="https://github.com/user-attachments/assets/2e42b3ca-f7cc-4c29-b0d7-6b762f880215" />

## Local Stack

The durable workflow stack runs locally against the real components:

- Postgres in Docker
- MinIO as an S3-compatible replica target for Litestream
- node-local SQLite files under `priv/workflow_data`
- the real `litestream` binary on your host `PATH`

Start the local resources:

```bash
docker compose -f docker-compose.resources.yml up -d
```

Useful local endpoints:

- App: [http://localhost:4000](http://localhost:4000)
- Adminer: [http://localhost:8080](http://localhost:8080)
- MinIO API: [http://localhost:9000](http://localhost:9000)
- MinIO Console: [http://localhost:9001](http://localhost:9001)

Development defaults are already wired for the workflow stack:

- bucket: `fizz-workflows-dev`
- endpoint: `http://127.0.0.1:9000`
- access key: `minioadmin`
- secret key: `minioadmin`
- workflow data dir: `priv/workflow_data`

Override them with environment variables when needed:

- `WORKFLOW_DATA_DIR`
- `LITESTREAM_S3_BUCKET`
- `LITESTREAM_S3_PREFIX`
- `LITESTREAM_AWS_REGION`
- `LITESTREAM_S3_ENDPOINT`
- `LITESTREAM_S3_SKIP_VERIFY`
- `LITESTREAM_LOG_LEVEL` (defaults to `warn`)
- `LITESTREAM_ACCESS_KEY_ID`
- `LITESTREAM_SECRET_ACCESS_KEY`

## App Setup

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
