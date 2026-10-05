package main

import "testing"

func TestNormalizePoll(t *testing.T) {
	question, options, selectable, err := normalizePoll("  Lunch? ", []string{" yes ", "", "no"}, false)
	if err != nil {
		t.Fatal(err)
	}
	if question != "Lunch?" || selectable != 1 || len(options) != 2 || options[0] != "yes" || options[1] != "no" {
		t.Fatalf("got %q %v %d", question, options, selectable)
	}

	_, _, selectable, err = normalizePoll("Lunch?", []string{"yes", "no"}, true)
	if err != nil || selectable != 0 {
		t.Fatalf("multiple: selectable=%d err=%v", selectable, err)
	}

	if _, _, _, err = normalizePoll("Lunch?", []string{"yes"}, false); err == nil {
		t.Fatal("expected too few options")
	}
	if _, _, _, err = normalizePoll("Lunch?", []string{"yes", "yes"}, false); err == nil {
		t.Fatal("expected duplicate option")
	}
}
