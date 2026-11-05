//go:build swiftfixture

// Writes Tests/DMCNKitTests/Fixtures/go-sealed.json: a message sealed by open-dmcn's Go
// implementation, which the Swift suite must open. The known-answer vectors pin encodings; this
// pins the whole path, Go's seal against Swift's open.
//
// It is not part of open-dmcn. `make go-fixture` copies it into the pinned open-dmcn checkout's
// internal/core/message (the package is internal, so it has to run from inside that module),
// runs it, and removes it again. The build tag keeps it out of open-dmcn's own test runs if a
// copy is ever left behind.

package message

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"dmcn.dev/open-dmcn/dmcnpb"
	"dmcn.dev/open-dmcn/internal/core/crypto"
)

func fixedBytes(n int, b byte) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}

func TestWriteSwiftFixture(t *testing.T) {
	out := os.Getenv("SWIFT_FIXTURE_OUT")
	if out == "" {
		t.Skip("SWIFT_FIXTURE_OUT not set")
	}

	senderPriv := ed25519.NewKeyFromSeed(fixedBytes(32, 0x01))
	var recipientPriv [crypto.X25519KeySize]byte
	copy(recipientPriv[:], fixedBytes(32, 0x02))
	recipientPub, err := crypto.X25519PublicFromPrivate(recipientPriv)
	if err != nil {
		t.Fatal(err)
	}

	var msgID, threadID, replyTo [16]byte
	copy(msgID[:], fixedBytes(16, 0x11))
	copy(threadID[:], fixedBytes(16, 0x22))
	copy(replyTo[:], fixedBytes(16, 0x33))

	msg := &PlaintextMessage{
		Version:          1,
		MessageID:        msgID,
		ThreadID:         threadID,
		SenderAddress:    "alice@parity.example",
		SenderPublicKey:  senderPriv.Public().(ed25519.PublicKey),
		RecipientAddress: "bob@parity.example",
		SentAt:           time.Unix(1_700_000_000, 0).UTC(),
		Subject:          "Sealed in Go, opened in Swift",
		Body:             MessageBody{ContentType: "text/plain", Content: []byte("Hello from Go. ünïcödé ✓")},
		Alternatives:     []MessageBody{{ContentType: "text/html", Content: []byte("<p>Hello from <b>Go</b>.</p>")}},
		ReplyToID:        replyTo,
		SenderDisplay:    "Alice",
	}
	sh, content, err := Split(msg, senderPriv)
	if err != nil {
		t.Fatal(err)
	}
	rcpt := RecipientInfo{X25519Pub: recipientPub}
	env, err := EncryptSplit(sh, content, []RecipientInfo{rcpt}, senderPriv)
	if err != nil {
		t.Fatal(err)
	}
	pb := env.ToProto()

	// What a relay files for this envelope (internal/relay's mailbox store).
	entry := &dmcnpb.MailboxEntry{
		Recipients:         pb.Recipients,
		EncryptedHeader:    pb.EncryptedHeader,
		HeaderNonce:        pb.HeaderNonce,
		HeaderTag:          pb.HeaderTag,
		HeaderSizeClass:    pb.HeaderSizeClass,
		BodyContentAddress: pb.BodyContentAddress,
	}
	body := &dmcnpb.MailboxBody{
		EncryptedBody:      pb.EncryptedBody,
		BodyNonce:          pb.BodyNonce,
		BodyTag:            pb.BodyTag,
		BodySizeClass:      pb.BodySizeClass,
		BodyContentAddress: pb.BodyContentAddress,
	}
	det := proto.MarshalOptions{Deterministic: true}
	entryBytes, err := det.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	bodyBytes, err := det.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}

	fixture := map[string]string{
		"recipient_x25519_private": hex.EncodeToString(recipientPriv[:]),
		"sender_ed25519_public":    hex.EncodeToString(senderPriv.Public().(ed25519.PublicKey)),
		"entry":                    hex.EncodeToString(entryBytes),
		"body":                     hex.EncodeToString(bodyBytes),
	}
	data, err := json.MarshalIndent(fixture, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(out, append(data, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}
