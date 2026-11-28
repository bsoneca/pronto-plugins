package externalsecret

// What a tenant's ExternalSecret may be (PRONTO-2146, #TenantExternalSecret): the cases as data, held three ways. tests/tenant.cue renders each into a tenant's release and
// holds `says` as its violations, exactly; release_test.nu runs each through tenant.nu's check-objects (in the namespace `ns`) and holds that each `says` is in its refusal.
// `cue vet ./node/engine/tests/externalsecret` holds the shape.

#Case: {
	ns:   string
	name: string
	// the object a tenant's publisher writes
	object: {apiVersion: "external-secrets.io/v1beta1", kind: "ExternalSecret", metadata: {"name": name, namespace: ns}, spec: {...}}
	// the reasons it is refused for, in the order the schema says them: none when it passes
	says: [...string]
	// the words of the CRD's own refusal, for a case the served ExternalSecret CRD's schema refuses before any policy runs (an unknown field, a required value): the API-server half of
	// admission_test.nu expects that and not the policy's
	crd?: string
}

// A tenant's Password generator (PRONTO-2147, #TenantExternalSecret.passwordKeys), held the same ways as an ExternalSecret.
#GeneratorCase: {
	ns:   string
	name: string
	object: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", metadata: {"name": name, namespace: ns}, spec: {...}}
	says: [...string]
}

#Cases: {
	ns: string
	generators: {
		allowed: [string]: #GeneratorCase & {"ns": ns, name: *"gen" | string, says: []}
		refused: [string]: #GeneratorCase & {"ns": ns, name: *"gen" | string, says: [_, ...]}
		// upstream's: what the engine's logins and `<app>-db-postgres` draw from
		allowed: "is upstream's": object: spec: {length: 32, digits: 8, symbols: 0, noUpper: false, allowRepeat: true}
		// the value is then aaaa…: the tenant chose the database superuser's password
		refused: "yields a value of the tenant's choosing": object: spec: {length: 32, digits: 0, symbols: 32, symbolCharacters: "a", allowRepeat: true}
		refused: "yields a value of the tenant's choosing": says: [
			"Password/gen sets spec.symbolCharacters, which a tenant's generator may not (#TenantExternalSecret.passwordKeys)",
			"Password/gen sets spec.symbols, which a tenant's generator has none of (#TenantExternalSecret)",
		]
		refused: "is short": object: spec: {length: 8}
		refused: "is short": says: ["Password/gen sets spec.length below 24 (#TenantExternalSecret.passwordMinLength)"]
	}
	allowed: [string]:   #Case
	refused: [string]:   #Case
	allowed: [K=string]: {"ns": ns, name: *"ok" | string, says: []}
	refused: [K=string]: {"ns": ns, name: *"steal" | string, says: [_, ...]}

	// A Password generator's value, drawn by name.
	allowed: "draws a Password generator's value": {
		name: "app-pw"
		object: spec: target: name: "app-pw"
	}
	allowed: "draws a Password generator's value": object: spec: {
		dataFrom: [{sourceRef: generatorRef: {kind: "Password", name: "app-pw-gen"}}]
	}
	// upstream pronto v1.5.1's `<app>-db-postgres` (k8s/schema/k8s.cue): an empty `data`, the generator's value renamed, a basic-auth template.
	allowed: "has the shape of upstream's db-postgres": {
		name: "app-db-postgres"
		object: spec: {
			refreshInterval: "0"
			target:          {name: "app-db-postgres", creationPolicy: "Owner", template: {type: "kubernetes.io/basic-auth", data: {username: "postgres", password: "{{ .POSTGRES_PASSWORD }}"}}}
			data:            []
			dataFrom: [{
				sourceRef: generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: "app-postgres-password"}
				rewrite: [{regexp: {source: "password", target: "POSTGRES_PASSWORD"}}]
			}]
		}
	}

	// PRONTO-2147: the Secret it writes. The engine's own login ExternalSecret (`<release>-<login>-db`, Owner, a url beside the password) is one the rules let through.
	allowed: "writes its own Secret as its Owner": object: spec: {
		target: {name: "ok", creationPolicy: "Owner", template: {type: "kubernetes.io/basic-auth", data: {username: "u", password: "{{ .U_PASSWORD }}", url: "postgres://u:{{ .U_PASSWORD }}@database:5432/app"}}}
		dataFrom: [{sourceRef: generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: "g"}, rewrite: [{regexp: {source: "password", target: "U_PASSWORD"}}]}]
	}

	refused: "merges into the cluster's superuser Secret": {
		name: "app-db-superuser"
		object: spec: {
			target: {creationPolicy: "Merge", template: data: password: "chosen"}
			dataFrom: [{sourceRef: generatorRef: {kind: "Password", name: "g"}}]
		}
		says: [
			"ExternalSecret/app-db-superuser sets spec.target.creationPolicy Merge: a tenant's ExternalSecret creates its Secret as its Owner alone (#TenantExternalSecret)",
			"ExternalSecret/app-db-superuser writes a Secret that holds a database's superuser password (#TenantGuardedSecretSuffixes)",
		]
	}
	refused: "targets a Secret of another name": {
		object: spec: target: {name: "app-db-postgres", creationPolicy: "Merge"}
		says: [
			"ExternalSecret/steal sets spec.target.name app-db-postgres, which is not its own name: a tenant's ExternalSecret writes the Secret of its own name (#TenantExternalSecret)",
			"ExternalSecret/steal sets spec.target.creationPolicy Merge: a tenant's ExternalSecret creates its Secret as its Owner alone (#TenantExternalSecret)",
		]
	}
	refused: "orphans or keeps no ownership of its Secret": {
		object: spec: target: creationPolicy: "Orphan"
		says: ["ExternalSecret/steal sets spec.target.creationPolicy Orphan: a tenant's ExternalSecret creates its Secret as its Owner alone (#TenantExternalSecret)"]
	}
	refused: "writes the database Secret with a password of its own": {
		name: "app-db-postgres"
		object: spec: target: template: data: {username: "postgres", password: "chosen"}
		says: ["ExternalSecret/app-db-postgres sets a database Secret's password that is no reference to a generated key, but a value of its own (#TenantExternalSecret)"]
	}
	refused: "writes the database Secret with a template source and a key of its own": {
		name: "app-db-postgres"
		object: spec: target: template: {templateFrom: [{secret: name: "other"}], data: {username: "postgres", password: "{{ .P }}", extra: "x"}}
		says: [
			"ExternalSecret/app-db-postgres sets spec.target.template.templateFrom on a database Secret (#TenantExternalSecret)",
			"ExternalSecret/app-db-postgres sets spec.target.template.data.extra on a database Secret, which holds only username and password (#TenantExternalSecret)",
		]
	}
	refused: "writes another release's database Secret": {
		name: "other-db-postgres"
		object: spec: target: creationPolicy: "Owner"
		says: ["ExternalSecret/other-db-postgres writes a database Secret that is not app-db-postgres: a tenant's database is the release's own (#TenantExternalSecret)"]
	}

	refused: "names a ClusterSecretStore and looks a key up in it": object: spec: {
		secretStoreRef: {name: "operator", kind: "ClusterSecretStore"}
		target: name: "steal"
		data: [{secretKey: "k", remoteRef: key: "other-tenant/secret"}]
	}
	refused: "names a ClusterSecretStore and looks a key up in it": says: [
		"ExternalSecret/steal sets spec.secretStoreRef, which names a store: a tenant's ExternalSecret reads none (#TenantExternalSecret)",
		"ExternalSecret/steal sets spec.data, a lookup in a store: a tenant's ExternalSecret reads none (#TenantExternalSecret)",
	]
	refused: "names a SecretStore": object: spec: {
		secretStoreRef: {name: "somewhere", kind: "SecretStore"}
		target: name: "steal"
	}
	refused: "names a SecretStore": says: ["ExternalSecret/steal sets spec.secretStoreRef, which names a store: a tenant's ExternalSecret reads none (#TenantExternalSecret)"]
	refused: "names an empty store reference": object: spec: {
		secretStoreRef: {}
		target: name: "steal"
	}
	refused: "names an empty store reference": crd: "Required value"
	refused: "names an empty store reference": says: ["ExternalSecret/steal sets spec.secretStoreRef, which names a store: a tenant's ExternalSecret reads none (#TenantExternalSecret)"]
	refused: "extracts or finds in a store": object: spec: {
		target: name: "steal"
		dataFrom: [{extract: key: "other-tenant/secret"}, {find: name: regexp: ".*"}]
	}
	refused: "extracts or finds in a store": says: [
		"ExternalSecret/steal spec.dataFrom[0] sets extract, which a tenant's ExternalSecret may not (#TenantExternalSecret)",
		"ExternalSecret/steal spec.dataFrom[1] sets find, which a tenant's ExternalSecret may not (#TenantExternalSecret)",
		"ExternalSecret/steal spec.dataFrom[0] has no sourceRef.generatorRef (#TenantExternalSecret)",
		"ExternalSecret/steal spec.dataFrom[1] has no sourceRef.generatorRef (#TenantExternalSecret)",
	]
	refused: "draws through a sourceRef store or a generator that is no Password": object: spec: {
		target: name: "steal"
		dataFrom: [
			{sourceRef: storeRef: {name: "operator", kind: "ClusterSecretStore"}},
			{sourceRef: generatorRef: {kind: "ClusterGenerator", name: "g"}},
			{sourceRef: generatorRef: {apiVersion: "generators.external-secrets.io/v1beta1", kind: "Password", name: "g"}},
		]
	}
	refused: "draws through a sourceRef store or a generator that is no Password": says: [
		"ExternalSecret/steal spec.dataFrom[0].sourceRef sets storeRef, a store: a tenant's ExternalSecret draws from a generator alone (#TenantExternalSecret)",
		"ExternalSecret/steal spec.dataFrom[0].sourceRef has no generatorRef (#TenantExternalSecret)",
		"ExternalSecret/steal spec.dataFrom[1] draws from a generator of kind ClusterGenerator, which is no Password (#TenantExternalSecret.generatorKinds)",
		"ExternalSecret/steal spec.dataFrom[2] draws from a generator of generators.external-secrets.io/v1beta1, not generators.external-secrets.io/v1alpha1 (#TenantExternalSecret)",
	]

	// upstream pronto's `<app>-auth-secrets` (k8s/schema/k8s.cue prontoExternalSecretObj): no template, two generators renamed, an empty `data`.
	allowed: "has the shape of upstream's auth-secrets": {
		name: "app-auth-secrets"
		object: spec: {
			refreshInterval: "0"
			target: {name: "app-auth-secrets", creationPolicy: "Owner"}
			data: []
			dataFrom: [{
				sourceRef: generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: "app-pgrst-jwt-secret"}
				rewrite: [{regexp: {source: "password", target: "PGRST_JWT_SECRET"}}]
			}, {
				sourceRef: generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: "app-electric-secret"}
				rewrite: [{regexp: {source: "password", target: "ELECTRIC_SECRET"}}]
			}]
		}
	}

	refused: "sets a generatorRef namespace": object: spec: {
		target: name: "steal"
		dataFrom: [{sourceRef: generatorRef: {kind: "Password", name: "g", namespace: "other-tenant"}}]
	}
	refused: "sets a generatorRef namespace": crd: "unknown field"
	refused: "sets a generatorRef namespace": says: ["ExternalSecret/steal spec.dataFrom[0].sourceRef.generatorRef sets namespace, which a tenant's ExternalSecret may not (#TenantExternalSecret)"]
	refused: "draws from a generator with no kind": object: spec: {
		target: name: "steal"
		dataFrom: [{sourceRef: generatorRef: {name: "g"}}]
	}
	refused: "draws from a generator with no kind": crd: "Required value"
	refused: "draws from a generator with no kind": says: ["ExternalSecret/steal spec.dataFrom[0] draws from a generator with no kind (#TenantExternalSecret.generatorKinds)"]
	refused: "sets a spec key outside the allowed ones": object: spec: {
		refreshPolicy: "OnChange"
		target: name:  "steal"
		dataFrom: [{sourceRef: generatorRef: {kind: "Password", name: "g"}}]
	}
	refused: "sets a spec key outside the allowed ones": crd: "unknown field"
	refused: "sets a spec key outside the allowed ones": says: ["ExternalSecret/steal sets spec.refreshPolicy, which a tenant's ExternalSecret may not (#TenantExternalSecret)"]
}
