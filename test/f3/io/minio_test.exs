defmodule F3.IO.MinIOTest do
  use ExUnit.Case, async: false

  @moduletag :minio

  test "signed head against an endpoint the operator already started" do
    endpoint = System.get_env("F3_MINIO_ENDPOINT")
    bucket = System.get_env("F3_MINIO_BUCKET")
    key = System.get_env("F3_MINIO_KEY")
    region = System.get_env("F3_MINIO_REGION") || "us-east-1"
    access_key = System.get_env("F3_MINIO_ACCESS_KEY")
    secret_key = System.get_env("F3_MINIO_SECRET_KEY")

    missing =
      Enum.any?([endpoint, bucket, key, access_key, secret_key], fn value ->
        not is_binary(value) or value == ""
      end)

    if missing do
      flunk(
        "F3_MINIO=1 requires F3_MINIO_ENDPOINT, F3_MINIO_BUCKET, F3_MINIO_KEY, F3_MINIO_ACCESS_KEY, and F3_MINIO_SECRET_KEY"
      )
    end

    assert {:ok, file} =
             F3.open(key,
               source:
                 {:http, endpoint,
                  endpoint: endpoint,
                  bucket: bucket,
                  key: key,
                  region: region,
                  access_key: access_key,
                  secret_key: secret_key}
             )

    refute inspect(file) =~ secret_key
    {:ok, _} = F3.close(file)
  end
end
