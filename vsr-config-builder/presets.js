/* presets.js — worked plans the wizard can load instead of starting empty.
 *
 * `task-routing` is the config from agentgateway-inference-task-routing-eks, expressed
 * as wizard answers. It is here so the page can demonstrate itself on something real
 * rather than on a toy, and so a reader following Part 4 can open their own lab's
 * config, change one category and see what it does to the decisions.
 *
 * It is not a byte-for-byte reproduction of `10-router-tasks.yaml`. That file carries
 * two hand-written decisions the wizard does not generate: `code_review_in_code` and
 * `code_modification_in_code`, which drop the domain condition because a prompt with a
 * long code block attached hands the classifier the vocabulary of the code rather than
 * of the question. Ledger code reads as business. The wizard gets you the other seven
 * decisions and the signals; that pair is a tuning step you make afterwards, and the
 * page says so.
 */
(function (root) {
  'use strict';

  var CODING_QUESTIONS = [
    'Show an example of dependency injection in Java',
    'How do I read a file in Python',
    'What is the difference between a list and a set',
    'Explain how a hash map works',
    'Give an example of a REST client in Go',
    'How does garbage collection work in the JVM'
  ];

  var PRESETS = {
    // First on purpose. Data class is the case the wizard explains best, because the
    // three classes are not subjects: the domain classifier has no label for "must
    // stay in the EU", so the whole config has to be built from phrasings and words.
    // Deliberately generic. Anyone with a data classification policy should recognise
    // their own three tiers here without having to translate from someone else's
    // industry.
    'data-classes': {
      title: 'Three data classes: anywhere, EU only, never leaves',
      blurb: 'One class of data that can go to any approved model, one that must stay ' +
        'on models hosted in the EU, and one that must never reach a model you do not ' +
        'run yourself. Usually that distinction lives in a policy document and in a few ' +
        'people\'s heads, and every developer is trusted to apply it. This is the same ' +
        'rule applied to every prompt instead.',
      plan: {
        endpoint: 'model-gateway.agentgateway-system.svc.cluster.local:80',

        // The fallback is the strictest class, not the loosest. A prompt nobody can
        // classify is exactly the prompt you do not want leaving the building, and it
        // is the answer to "developers cannot be trusted to know which class it is":
        // they do not have to know, because not knowing keeps it at home.
        fallback: 'class_3_never_leaves',

        categories: [
          {
            name: 'class_3_never_leaves',
            description: 'Never reaches a model we do not host ourselves',
            domains: [],
            keywords: ['strictly confidential', 'confidential', 'restricted',
              'internal only', 'proprietary', 'trade secret', 'commercially sensitive',
              'do not distribute', 'under embargo', 'board only'],
            phrases: [
              'Review the draft terms in the attached contract before we send it out',
              'Summarise how our pricing model works for the new tier',
              'What does this internal incident report say about the root cause',
              'Compare the margins on our two largest accounts',
              'Check this board paper before it goes to the meeting',
              'Draft a reply to the supplier without revealing what it costs us to make'
            ]
          },
          {
            name: 'class_2_eu_only',
            description: 'Holds personal data, so it stays on EU-hosted models',
            domains: [],
            keywords: ['personal data', 'personally identifiable', 'data subject',
              'staff record', 'employee', 'payroll', 'salary', 'home address',
              'date of birth', 'customer details', 'consent', 'grievance', 'sick leave'],
            phrases: [
              'Summarise this grievance raised by a member of staff',
              'What is the correct process when someone asks to see the data we hold on them',
              'Draft a letter to the employee about the change to their contract',
              'Check the staff records in this export for anything out of date',
              'Prepare a note for HR on the absence dispute',
              'How should we handle a data subject access request from a former employee'
            ]
          },
          {
            name: 'class_1_anywhere',
            description: 'Nothing confidential and nobody named, so any approved model may answer',
            domains: [],
            keywords: [],
            phrases: [
              'Write an outline for a conference talk next year',
              'Explain how a content delivery network works',
              'Draft a post about our sustainability targets',
              'What is the difference between a rate limit and a quota',
              'Summarise the main trends in our industry this year',
              'Suggest a structure for a press release about a product launch'
            ]
          }
        ],
        pairs: [
          { a: 'class_3_never_leaves', b: 'class_1_anywhere' },
          { a: 'class_2_eu_only', b: 'class_1_anywhere' },
          { a: 'class_3_never_leaves', b: 'class_2_eu_only' }
        ]
      }
    },

    'task-routing': {
      title: 'Task routing, from the Part 4 lab',
      blurb: 'Six labels for a bank that also runs a network: two kinds of work on ' +
        'existing code, a general coding question, its own subject, the operator ' +
        'network, and a fallback for everything it is not sure about.',

      // The real file, fetched from the lab rather than copied here, so the example
      // cannot drift from the config the lab actually deploys and tests.
      example: {
        url: '/solo/agentgateway-inference-task-routing-eks/yaml/10-router-tasks.yaml',
        absolute: 'https://mastertheagent.com/solo/agentgateway-inference-task-routing-eks/' +
          'yaml/10-router-tasks.yaml',
        lab: '/solo/agentgateway-inference-task-routing-eks/',
        name: '10-router-tasks.yaml',
        // What the wizard will not reproduce, and why. Worth saying plainly: a reader
        // who diffs the two should find the difference explained rather than be left
        // wondering which one is wrong.
        differences: [
          'Two decisions the wizard does not generate: <code>code_review_in_code</code> ' +
          'and <code>code_modification_in_code</code>. Both drop the domain condition, ' +
          'because a real prompt arrives with the file attached and a long code block ' +
          'hands the classifier the vocabulary of the code rather than of the question. ' +
          'Ledger code reads as business, not computer science.',
          'The lab\'s comments. They are most of the file and they are the teaching ' +
          'material, so read the real one for the reasoning behind each threshold.',
          'Hand-tuned priorities. The lab interleaves them by specificity across ' +
          'categories; the wizard lays them out ten apart from your ordering.'
        ]
      },
      plan: {
        endpoint: 'model-gateway.agentgateway-system.svc.cluster.local:80',
        fallback: 'uncertain',
        categories: [
          {
            name: 'telco',
            description: 'The operator\'s own network',
            // Both signals must hold. This category outranks every other, and that is
            // only safe because a prompt with no network vocabulary in it cannot match.
            match: 'both',
            domains: [],
            keywords: ['5G', 'LTE', 'RAN', 'radio access network', 'gNodeB', 'eNodeB',
              'VoLTE', 'IMS', 'MSISDN', 'SIM', 'roaming', 'network slice',
              'network slicing', 'BSS', 'OSS', 'core network', 'subscriber',
              'spectrum', 'base station', 'cell site', 'MVNO', 'interconnect',
              'backhaul', 'mobile network', 'tariff', 'churn'],
            phrases: [
              'How does a 5G network slice guarantee latency for an enterprise customer',
              'What happens during an LTE to 5G handover at the cell edge',
              'How is a subscriber authenticated when roaming onto a partner network',
              'What does the IMS core do when a VoLTE call is set up',
              'How should we dimension backhaul capacity for a new base station',
              'What is the difference between the radio access network and the mobile core'
            ]
          },
          {
            name: 'code_review',
            description: 'Looking at existing code',
            domains: ['computer science'],
            keywords: ['review', 'audit', 'look over', 'any bugs', 'critique', 'feedback'],
            phrases: [
              'Review this function and point out any problems',
              'Look over this code and tell me what is wrong with it',
              'Check this method for thread-safety issues',
              'Audit this class for security problems',
              'Are there any bugs in the following code',
              'Give me feedback on this implementation'
            ]
          },
          {
            name: 'code_modification',
            description: 'Changing existing code',
            domains: ['computer science'],
            keywords: ['modify', 'change', 'refactor', 'fix', 'rewrite', 'update',
              'add a', 'convert', 'migrate'],
            phrases: [
              'Modify this function so that it handles the new case',
              'Change this method to use the new API',
              'Refactor this service to remove the duplication',
              'Fix the bug in the following code',
              'Rewrite this function to be thread safe',
              'Update this class to add a retry'
            ]
          },
          {
            name: 'finance',
            description: 'The bank\'s own subject',
            domains: ['economics', 'business'],
            keywords: [],
            phrases: [
              'What effect does a central bank raising interest rates have on bond prices',
              'How should a company account for deferred revenue on multi-year contracts',
              'Summarise the main provisions of a commercial lease'
            ]
          },
          {
            name: 'generic_coding',
            description: 'A coding question about no code of ours',
            domains: ['computer science'],
            keywords: [],
            phrases: CODING_QUESTIONS.slice()
          }
        ],
        pairs: [
          { a: 'code_review', b: 'generic_coding' },
          { a: 'code_modification', b: 'generic_coding' },
          { a: 'code_review', b: 'code_modification' },
          { a: 'telco', b: '*' }
        ]
      }
    },

    'blank': {
      title: 'Start from nothing',
      blurb: 'Two categories and a fallback, so the shape is visible and every answer ' +
        'is yours.',
      plan: {
        endpoint: 'model-gateway.agentgateway-system.svc.cluster.local:80',
        fallback: 'uncertain',
        categories: [
          { name: 'sensitive', description: '', domains: [], keywords: [], phrases: [] },
          { name: 'general', description: '', domains: [], keywords: [], phrases: [] }
        ],
        pairs: []
      }
    }
  };

  /* --------------------------------------------------------------- snippets --
   * A catalogue of ready-made signals to drop into a category, so nobody has to
   * invent six phrasings from a blank box. They are starting points and they are
   * meant to be edited: the phrasings are the definition of your category, and the
   * ones that matter are the ones that sound like your own people.
   *
   * Grouped so the list reads as "what kind of thing is this category about".
   */
  var SNIPPETS = [
    {
      group: 'Data classes',
      items: [
        {
          label: 'Confidential, must not leave',
          keywords: ['strictly confidential', 'confidential', 'restricted',
            'internal only', 'proprietary', 'trade secret', 'commercially sensitive',
            'do not distribute', 'under embargo', 'board only'],
          phrases: [
            'Review the draft terms in the attached contract before we send it out',
            'Summarise how our pricing model works for the new tier',
            'What does this internal incident report say about the root cause',
            'Compare the margins on our two largest accounts',
            'Check this board paper before it goes to the meeting',
            'Draft a reply to the supplier without revealing what it costs us to make'
          ]
        },
        {
          label: 'Personal data, keep it in region',
          keywords: ['personal data', 'personally identifiable', 'data subject',
            'staff record', 'employee', 'payroll', 'salary', 'home address',
            'date of birth', 'customer details', 'consent', 'grievance', 'sick leave'],
          phrases: [
            'Summarise this grievance raised by a member of staff',
            'What is the correct process when someone asks to see the data we hold on them',
            'Draft a letter to the employee about the change to their contract',
            'Check the staff records in this export for anything out of date',
            'Prepare a note for HR on the absence dispute',
            'How should we handle a data subject access request from a former employee'
          ]
        },
        {
          label: 'Public, nothing confidential in it',
          keywords: [],
          phrases: [
            'Write an outline for a conference talk next year',
            'Explain how a content delivery network works',
            'Draft a post about our sustainability targets',
            'What is the difference between a rate limit and a quota',
            'Summarise the main trends in our industry this year',
            'Suggest a structure for a press release about a product launch'
          ]
        }
      ]
    },
    {
      group: 'Kinds of work',
      items: [
        {
          label: 'Looking at code we already have',
          keywords: ['review', 'audit', 'look over', 'any bugs', 'critique', 'feedback'],
          phrases: [
            'Review this function and point out any problems',
            'Look over this code and tell me what is wrong with it',
            'Check this method for thread-safety issues',
            'Audit this class for security problems',
            'Are there any bugs in the following code',
            'Give me feedback on this implementation'
          ]
        },
        {
          label: 'Changing code we already have',
          keywords: ['modify', 'change', 'refactor', 'fix', 'rewrite', 'update', 'add a',
            'convert', 'migrate'],
          phrases: [
            'Modify this function so that it handles the new case',
            'Change this method to use the new API',
            'Refactor this service to remove the duplication',
            'Fix the bug in the following code',
            'Rewrite this function to be thread safe',
            'Update this class to add a retry'
          ]
        },
        {
          label: 'A general question about no code of ours',
          keywords: [],
          phrases: CODING_QUESTIONS.slice()
        },
        {
          label: 'A question from a customer',
          keywords: ['customer', 'ticket', 'complaint', 'refund', 'order number',
            'delivery', 'warranty', 'return'],
          phrases: [
            'Draft a reply to this customer asking where their order is',
            'The customer says the part arrived damaged, what should we offer',
            'Summarise this support ticket for the account manager',
            'Explain our warranty terms in plain language for a customer',
            'Write a holding reply while we investigate the complaint',
            'How should we respond to a refund request outside the return window'
          ]
        }
      ]
    },
    {
      group: 'Subjects',
      items: [
        {
          label: 'Money and markets',
          keywords: ['invoice', 'ledger', 'revenue', 'forecast', 'margin', 'budget',
            'audit', 'balance sheet'],
          phrases: [
            'What effect does a central bank raising interest rates have on bond prices',
            'How should a company account for deferred revenue on multi-year contracts',
            'Explain the difference between gross and net margin',
            'What goes into a three-statement financial model',
            'How is goodwill treated after an acquisition',
            'Summarise the main risks in this quarterly forecast'
          ]
        },
        {
          label: 'Networks and telecoms',
          keywords: ['5G', 'LTE', 'RAN', 'radio access network', 'VoLTE', 'IMS', 'SIM',
            'roaming', 'network slice', 'core network', 'subscriber', 'base station',
            'backhaul'],
          phrases: [
            'How does a 5G network slice guarantee latency for an enterprise customer',
            'What happens during an LTE to 5G handover at the cell edge',
            'How is a subscriber authenticated when roaming onto a partner network',
            'What does the IMS core do when a VoLTE call is set up',
            'How should we dimension backhaul capacity for a new base station',
            'What is the difference between the radio access network and the mobile core'
          ]
        },
        {
          label: 'Legal and contracts',
          keywords: ['contract', 'clause', 'liability', 'indemnity', 'termination',
            'NDA', 'compliance', 'regulation'],
          phrases: [
            'Summarise the main provisions of a commercial lease',
            'What does this limitation of liability clause actually limit',
            'Explain the notice period for terminating this agreement',
            'Is this indemnity clause unusual for a supplier contract',
            'What are our obligations under this data processing agreement',
            'Draft a short NDA for a supplier conversation'
          ]
        }
      ]
    }
  ];

  root.VSR_PRESETS = PRESETS;
  root.VSR_SNIPPETS = SNIPPETS;
})(typeof window !== 'undefined' ? window : globalThis);
