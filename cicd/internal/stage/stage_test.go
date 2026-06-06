package stage

import (
	"testing"
)

func TestManagerCRUD(t *testing.T) {
	m := New()
	m.stages = nil
	if err := m.Add("test", Options{Host: "1.2.3.4", Port: 22, AuthMethod: "key", Branch: "develop"}); err != nil {
		t.Fatal(err)
	}
	if err := m.Update("test", Options{Host: "5.6.7.8", Port: 2200}); err != nil {
		t.Fatal(err)
	}
	got := m.Get("test")
	if got == nil || got.Host != "5.6.7.8" || got.Port != 2200 {
		t.Fatalf("unexpected stage: %#v", got)
	}
	if err := m.Remove("test"); err != nil {
		t.Fatal(err)
	}
	if m.Get("test") != nil {
		t.Fatal("stage should be removed")
	}
}
