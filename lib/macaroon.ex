defmodule Macaroon do
  alias Macaroon.Types
  alias Macaroon.Util

  alias Macaroon.Serializers.Binary
  alias Macaroon.Serializers.JSON

  @spec create_macaroon(binary, binary, binary) :: Types.Macaroon.t()
  def create_macaroon(location, public_identifier, secret)
      when is_binary(location) and is_binary(public_identifier) and is_binary(secret) do
    derived_key = Util.Crypto.create_derived_key(secret)
    initial_sig = :crypto.hmac(:sha256, derived_key, public_identifier)

    Types.Macaroon.build(
      location: location,
      public_identifier: public_identifier,
      signature: initial_sig
    )
  end

  @spec add_first_party_caveat(Macaroon.Types.Macaroon.t(), binary) :: Macaroon.Types.Macaroon.t()
  def add_first_party_caveat(%Types.Macaroon{} = macaroon, caveat_predicate)
      when is_binary(caveat_predicate) do
    c =
      Types.Caveat.build(
        caveat_id: caveat_predicate,
        party: :first
      )

    new_sig = :crypto.hmac(:sha256, macaroon.signature, caveat_predicate)

    %Types.Macaroon{
      macaroon
      | signature: new_sig,
        first_party_caveats: [c | macaroon.first_party_caveats]
    }
  end

  @spec add_third_party_caveat(
          Macaroon.Types.Macaroon.t(),
          binary,
          binary,
          binary,
          false | nil | binary
        ) :: Macaroon.Types.Macaroon.t()
  def add_third_party_caveat(
        %Types.Macaroon{} = macaroon,
        location,
        caveat_id,
        caveat_key,
        nonce \\ nil
      )
      when is_binary(location) and is_binary(caveat_id) and is_binary(caveat_key) do
    derived_key =
      caveat_key
      |> Util.Crypto.create_derived_key()
      |> Util.Crypto.truncate_or_pad_string()

    old_key = Util.Crypto.truncate_or_pad_string(macaroon.signature, :enacl.secretbox_KEYBYTES())

    nonce = nonce || :crypto.strong_rand_bytes(:enacl.secretbox_NONCEBYTES())

    cipher_text = :enacl.secretbox(derived_key, nonce, old_key)

    verification_key_id = nonce <> cipher_text

    c =
      Types.Caveat.build(
        caveat_id: caveat_id,
        location: location,
        verification_key_id: verification_key_id,
        party: :third
      )

    concat_digest = Util.Crypto.hmac_concat(macaroon.signature, verification_key_id, caveat_id)

    %Types.Macaroon{
      macaroon
      | signature: concat_digest,
        third_party_caveats: [c | macaroon.third_party_caveats]
    }
  end

  @spec prepare_for_request(Macaroon.Types.Macaroon.t(), Macaroon.Types.Macaroon.t()) ::
          Macaroon.Types.Macaroon.t()
  def prepare_for_request(%Types.Macaroon{} = discharge_macaroon, %Types.Macaroon{} = macaroon) do
    copy = discharge_macaroon
    key = Util.Crypto.truncate_or_pad_string(<<0>>, :enacl.secretbox_KEYBYTES())
    new_sig = Util.Crypto.hmac_concat(key, macaroon.signature, discharge_macaroon.signature)
    %Types.Macaroon{copy | signature: new_sig}
  end

  @spec serialize(Macaroon.Types.Macaroon.t(), :binary | :json) ::
          nil
          | {:error,
             %{
               :__exception__ => any,
               :__struct__ => Jason.EncodeError | Protocol.UndefinedError,
               optional(atom) => any
             }}
          | {:ok, binary}
  def serialize(%Types.Macaroon{} = macaroon, :json) do
    case JSON.encode(macaroon) do
      {:ok, _} = serialized -> serialized
      {:error, details} -> {:error, details}
    end
  end

  def serialize(%Types.Macaroon{} = macaroon, :binary) do
    Binary.encode(macaroon, :v1)
  end

  @spec deserialize(binary, :binary | :json) :: Macaroon.Types.Macaroon.t()
  def deserialize(macaroon_json, :json) when is_binary(macaroon_json) do
    JSON.decode(macaroon_json)
  end

  def deserialize(macaroon_binary, :binary) when is_binary(macaroon_binary) do
    Binary.decode(macaroon_binary, :v1)
  end
end
