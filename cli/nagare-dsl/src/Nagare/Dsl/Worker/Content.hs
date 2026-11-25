-- | The objects that route requests to a worker's HTTP port (EP-285): a
-- ClusterIP Service for any worker with a port, and, for a content route, a
-- cert-manager Certificate for @*.D@ and @D@ and a Knative @Ingress@ that
-- Kourier serves.
--
-- The Ingress is Nagare's own, not a @DomainMapping@: a DomainMapping is named
-- after one host, so it cannot be a wildcard, and it rewrites @Host@ to the
-- target's internal name. This Ingress sends every request for the route's
-- hosts to the worker's Service with the original @Host@ header, which is what
-- gives each document its own browser origin.
module Nagare.Dsl.Worker.Content
  ( workerServiceValue
  , contentCertificateValue
  , contentIngressValue
  , contentObjectName
  , contentDomainLabel
  , kourierIngressClass
  , renderWorkerRoute
  )
where

import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.ContentDomain (ContentRoute, WorkerHttp, contentDomainText, contentRouteHosts)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (namespaceText, portInt, serviceNameText)
import Nagare.Dsl.Worker (Worker)

-- | The Certificate, its Secret and the Ingress share this name.
contentObjectName :: Worker -> Text
contentObjectName w = "nagare-content-" <> serviceNameText (w ^. #name)

-- | The label that tells the certificate policy a public wildcard is a
-- content domain's.
contentDomainLabel :: Text
contentDomainLabel = "nagare.dev/content-domain"

kourierIngressClass :: Text
kourierIngressClass = "kourier.ingress.networking.knative.dev"

-- | A ClusterIP Service named after the worker, selecting its pods.
workerServiceValue :: Worker -> WorkerHttp -> Value
workerServiceValue w http =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata"
        .= object
          [ "name" .= serviceNameText (w ^. #name)
          , "namespace" .= namespaceText (w ^. #namespace)
          , "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text), "nagare.dev/worker" .= serviceNameText (w ^. #name)]
          ]
    , "spec"
        .= object
          [ "type" .= ("ClusterIP" :: Text)
          , "selector" .= object ["nagare.dev/worker" .= serviceNameText (w ^. #name)]
          , "ports"
              .= [ object
                     [ "name" .= ("http" :: Text)
                     , "port" .= portInt (http ^. #port)
                     , "targetPort" .= ("http" :: Text)
                     , "protocol" .= ("TCP" :: Text)
                     ]
                 ]
          ]
    ]

-- | The wildcard certificate for the route's hosts, from the named
-- ClusterIssuer (the compiler chooses it from the context).
contentCertificateValue :: Text -> Worker -> ContentRoute -> Value
contentCertificateValue issuer w route =
  object
    [ "apiVersion" .= ("cert-manager.io/v1" :: Text)
    , "kind" .= ("Certificate" :: Text)
    , "metadata"
        .= object
          [ "name" .= contentObjectName w
          , "namespace" .= namespaceText (w ^. #namespace)
          , "labels" .= object [contentDomainKey .= contentDomainText (route ^. #domain), "nagare.dev/managed-by" .= ("nagarectl" :: Text)]
          ]
    , "spec"
        .= object
          [ "secretName" .= contentObjectName w
          , "dnsNames" .= contentRouteHosts route
          , "issuerRef" .= object ["group" .= ("cert-manager.io" :: Text), "kind" .= ("ClusterIssuer" :: Text), "name" .= issuer]
          ]
    ]
  where
    contentDomainKey = "nagare.dev/content-domain"

-- | The Knative Ingress Kourier serves: every request for @*.D@ and @D@ goes to
-- the worker's Service on its port, over TLS, with plain HTTP redirected.
contentIngressValue :: Worker -> WorkerHttp -> ContentRoute -> Value
contentIngressValue w http route =
  object
    [ "apiVersion" .= ("networking.internal.knative.dev/v1alpha1" :: Text)
    , "kind" .= ("Ingress" :: Text)
    , "metadata"
        .= object
          [ "name" .= contentObjectName w
          , "namespace" .= namespace
          , "annotations" .= object ["networking.knative.dev/ingress.class" .= kourierIngressClass]
          , "labels" .= object ["nagare.dev/content-domain" .= contentDomainText (route ^. #domain), "nagare.dev/managed-by" .= ("nagarectl" :: Text)]
          ]
    , "spec"
        .= object
          [ "httpOption" .= ("Redirected" :: Text)
          , "tls" .= [object ["hosts" .= hosts, "secretName" .= contentObjectName w, "secretNamespace" .= namespace]]
          , "rules"
              .= [ object
                     [ "hosts" .= hosts
                     , "visibility" .= ("ExternalIP" :: Text)
                     , "http"
                         .= object
                           [ "paths"
                               .= [ object
                                      [ "splits"
                                          .= [ object
                                                 [ "serviceName" .= serviceNameText (w ^. #name)
                                                 , "serviceNamespace" .= namespace
                                                 , "servicePort" .= portInt (http ^. #port)
                                                 , "percent" .= (100 :: Int)
                                                 ]
                                             ]
                                      ]
                                  ]
                           ]
                     ]
                 ]
          ]
    ]
  where
    namespace = namespaceText (w ^. #namespace)
    hosts = contentRouteHosts route

-- | The route objects of one worker, in apply order: the Service, then the
-- Certificate and the Ingress when it has a content route. Empty for a worker
-- with no port.
renderWorkerRoute :: Text -> Worker -> [ByteString]
renderWorkerRoute issuer w = case w ^. #http of
  Nothing -> []
  Just http ->
    map (YP.encodePretty YP.defConfig) $
      workerServiceValue w http
        : concat [[contentCertificateValue issuer w route, contentIngressValue w http route] | Just route <- [http ^. #content]]
